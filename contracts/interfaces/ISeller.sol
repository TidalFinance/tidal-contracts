// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface ISeller {
    function assetBalance(uint256 assetIndex_) external view returns(uint256);
}
