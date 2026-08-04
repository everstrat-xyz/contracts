// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Mock ERC20 token for testing
 * @dev Provides a simple ERC20 implementation for testing purposes
 */
contract MockERC20 is ERC20 {
    error MockERC20TransferReverted();

    uint8 private _decimals;
    bool private _revertTransfer;
    bool private _returnFalseTransfer;
    bool private _noReturnTransfer;

    constructor(string memory _name, string memory _symbol, uint8 _tokenDecimals) ERC20(_name, _symbol) {
        _decimals = _tokenDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setRevertTransfer(bool revert_) external {
        _revertTransfer = revert_;
    }

    function setReturnFalseTransfer(bool returnFalse_) external {
        _returnFalseTransfer = returnFalse_;
    }

    /// @dev USDT-style: succeed but return no returndata (empty).
    function setNoReturnTransfer(bool noReturn_) external {
        _noReturnTransfer = noReturn_;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        _burn(_from, _amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (_returnFalseTransfer) {
            return false;
        }
        if (_noReturnTransfer) {
            _transfer(msg.sender, to, value);
            assembly {
                return(0, 0)
            }
        }
        return super.transfer(to, value);
    }

    /// @dev Blocks peer-to-peer transfers when `_revertTransfer` is set; mint/burn still work.
    function _update(address from, address to, uint256 value) internal override {
        if (_revertTransfer && from != address(0) && to != address(0)) {
            revert MockERC20TransferReverted();
        }
        super._update(from, to, value);
    }
}
