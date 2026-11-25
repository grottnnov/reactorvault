// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Executor-side mock of a Chainlink stock feed (IAggregatorV3).
///      Configurable price + updatedAt: the freshness re-check canon
///      (the brain computes WHEN, the executor checks NOW).
contract MockFeed {
    int256 public price;
    uint256 public updatedAt;
    uint80 public round = 1;

    function setRound(int256 price_, uint256 updatedAt_) external {
        price = price_;
        updatedAt = updatedAt_;
        round += 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (round, price, 0, updatedAt, round);
    }
}
