// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import '../Staking.sol';

contract StakingHelper {
    using SafeMath for uint;
    
    Staking public staking;
    
    constructor (address staking_) public {
        staking = Staking(staking_);
    }
    
    function getStakingAPR() external view returns (uint apr) {
        (uint256 totalSupply, uint256 rewardPerBlock,,,,) = staking.poolInfo();

        uint256 blockNumber;
        uint256 id;
        assembly {
            id := chainid()
        }
        
        if (id == 1 || id == 3) {
            blockNumber = 2102400;  // 15s per block, ETH Mainnet and Testnets
        } else if (id == 56 || id == 97) {
            blockNumber = 10512000;  // 3s per block, BSC Mainnet and Testnet
        } else if (id == 137 || id == 80001) {
            blockNumber = 15768000;  // 2s per block, Polygon Mainnet and Mumbai Testnet
        } else {
           blockNumber = 2102400;
        }
        
        apr = rewardPerBlock.mul(blockNumber).mul(10000).div(totalSupply);  // APR multiply by 10000
    }
}
