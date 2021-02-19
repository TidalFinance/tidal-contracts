// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IAssetManager {
    function getAssetLength() external view returns(uint256);
    function getAssetToken(uint256 index_) external view returns(address);
    function getAssetPolicy(uint256 index_) external view returns(address);
    function getAssetRiskLevel(uint256 index_) external view returns(uint256);
}
