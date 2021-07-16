// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IStaking {
    function startPayout(uint16 assetIndex_, uint256 payoutId_) external;
    function setPayout(uint16 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external;
}
