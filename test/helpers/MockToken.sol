// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    bool public failTransfers;
    bool public taxed;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackReturnData;
    bool public attempted;

    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFail(bool value) external {
        failTransfers = value;
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        attempted = false;
        callbackSucceeded = false;
        delete callbackReturnData;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        _callback();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        _callback();
        if (taxed) {
            _burn(from, amount / 100);
            return super.transferFrom(from, to, amount - amount / 100);
        }
        return super.transferFrom(from, to, amount);
    }

    function _callback() private {
        if (callbackTarget != address(0) && !attempted) {
            attempted = true;
            (callbackSucceeded, callbackReturnData) = callbackTarget.call(callbackData);
        }
    }
}

contract BrokenBalanceToken {
    fallback() external {
        revert("broken token");
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
