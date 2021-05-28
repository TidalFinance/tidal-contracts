// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import './Staking.sol';

contract StakingHelper {
    using SafeMath for uint;
    
    Staking staking;
    
    constructor (address staking_) public {
        staking = Staking(staking_);
    }
    
    function getStakingAPR() external view returns (uint apr) {
        (uint256 rewardPerBlock,,,,) = staking.poolInfo();
        uint256 totalSupply = staking.totalSupply();
        uint256 blockNumber;
        uint256 id;
        assembly {
            id := chainid()
        }
        if (id == 1) {
            blockNumber = 2102400;  //15s per block
        } else if (id == 56) {
            blockNumber = 10512000; //3s per block
        } else if (id == 137) {
            blockNumber = 15768000; //2s per block
        } else {
           blockNumber = 10512000; //3s per block
        }
        apr = rewardPerBlock.mul(blockNumber) / totalSupply;
    }
}