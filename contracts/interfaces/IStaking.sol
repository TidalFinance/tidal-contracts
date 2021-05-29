// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IStaking {
    function startPayout(uint256 payoutId_) external;
    function setPayout(uint256 payoutId_, address toAddress_, uint256 total_) external;
}
