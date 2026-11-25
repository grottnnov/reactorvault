// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IAggregatorV3 — minimal Chainlink feed view (executor side)
/// @notice The executor re-verifies price and freshness LOCALLY at
///         execution time (ADR-GUARD-RULES §2: the brain computes WHEN,
///         the executor checks NOW). 3-arg AnswerUpdated is the
///         subscription canon; latestRoundData is the verification one.
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
