// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPoolAdapter} from "../../src/IPoolAdapter.sol";

/// @dev Unit-test pool: ETH-denominated ledger, a settable rate, exact
///      settlement. Fork tests exercise the real Aave/Morpho adapters;
///      mocks live in tests only (repo canon).
contract MockPool is IPoolAdapter {
    uint256 public supplied;
    uint256 public ratePerYear = 0.05e18;

    function supply() external payable override {
        supplied += msg.value;
    }

    function withdraw(uint256 ethAmount) external override {
        supplied -= ethAmount; // reverts on underflow above the position
        (bool ok,) = msg.sender.call{value: ethAmount}("");
        require(ok, "MockPool: transfer failed");
    }

    function totalSupplied() external view override returns (uint256) {
        return supplied;
    }

    function supplyRatePerYear() external view override returns (uint256) {
        return ratePerYear;
    }

    function setRatePerYear(uint256 rate_) external {
        ratePerYear = rate_;
    }
}
