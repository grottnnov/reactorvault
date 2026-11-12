// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";

/// @dev Mock of the callback proxy's payer side (IPayable): tracks the
///      recipient's debt like the live proxy does. Incident #15: the
///      delivery pause is debt > 0, and only the recipient itself can
///      pay it off via _coverDebt(); the proxy exposes the debt() view.
contract MockCallbackProxy is IPayable {
    mapping(address => uint256) private _debts;

    function setDebt(address who_, uint256 amount_) external {
        _debts[who_] = amount_;
    }

    function debt(address contract_) external view override returns (uint256) {
        return _debts[contract_];
    }

    /// @dev A plain value transfer from a debtor reduces its debt —
    ///      this is how _coverDebt() settles on the live proxy.
    receive() external payable override {
        uint256 d = _debts[msg.sender];
        uint256 used = msg.value >= d ? d : msg.value;
        _debts[msg.sender] = d - used;
    }
}
