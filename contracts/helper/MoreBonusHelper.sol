// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../common/BaseRelayRecipient.sol";
import "../common/NonReentrancy.sol";

import "../interfaces/IAssetManager.sol";
import "../interfaces/IRegistry.sol";

interface ISeller {
    function userBasket(address who_, uint16 assetIndex_) external view returns(bool);
    function userBalance(address who_, uint8 category_) external view returns(uint256, uint256);
}

contract MoreBonusHelper is Ownable, NonReentrancy, BaseRelayRecipient {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address constant NATIVE_PLACEHOLDER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    string public override versionRecipient = "1.0.0";

    IRegistry public registry;

    struct PoolInfo {
        address token;
        uint256 amount;
        uint256 accRewardPerShare;
    }

    // assetIndex => PoolInfo
    mapping(uint16 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 amount;
        uint256 rewardAmount;
        uint256 rewardDebt; // Reward debt.
    }

    // assetIndex => who => UserInfo
    mapping(uint16 => mapping(address => UserInfo)) public userInfo;

    event SetToken(uint16 assetIndex_, address token_);
    event AddBonus(address indexed user_, uint16 assetIndex_, uint256 amount_);
    event Update(address indexed user_, uint16 assetIndex_);
    event Claim(address indexed user_, uint256 amount_);

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _msgSender() internal override(Context, BaseRelayRecipient) view returns (address payable) {
        return BaseRelayRecipient._msgSender();
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }

    function setToken(uint16 assetIndex_, address token_) external onlyOwner {
        poolInfo[assetIndex_].token = token_;
        emit SetToken(assetIndex_, token_);
    }

    // Adds bonus --> Step 2.
    function addBonus(uint16 assetIndex_, uint256 amount_) external lock {
        PoolInfo storage pool = poolInfo[assetIndex_];

        require(pool.token != address(0), "Token not set");
        require(pool.amount > 0, "Pool amount non-zero");

        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount_);

        pool.accRewardPerShare = pool.accRewardPerShare.add(
            amount_.mul(registry.UNIT_PER_SHARE()).div(pool.amount));

        emit AddBonus(msg.sender, assetIndex_, amount_);
    }

    // Adds bonus --> Step 2.
    function addBonusNative(uint16 assetIndex_, uint256 amount_) external payable lock {
        PoolInfo storage pool = poolInfo[assetIndex_];

        require(pool.token == NATIVE_PLACEHOLDER, "Token not native");
        require(pool.amount > 0, "Pool amount non-zero");
        require(msg.value == amount_, "Amount not sent");

        pool.accRewardPerShare = pool.accRewardPerShare.add(
            amount_.mul(registry.UNIT_PER_SHARE()).div(pool.amount));

        emit AddBonus(msg.sender, assetIndex_, amount_);
    }

    function getUserSellerBalance(address who_, uint16 assetIndex_) public view returns(uint256) {
        if (!ISeller(registry.seller()).userBasket(who_, assetIndex_)) {
            return 0;
        }

        (uint256 currentBalance, ) = ISeller(registry.seller()).userBalance(
            who_, IAssetManager(registry.assetManager()).getAssetCategory(assetIndex_));
        return currentBalance;
    }

    function massUpdate(address who_, uint16[] memory assetIndexArray_) external {
        for (uint256 i = 0; i < assetIndexArray_.length; ++i) {
            update(who_, assetIndexArray_[i]);
        }
    }

    // Every week update. ---> Step 1.
    function update(address who_, uint16 assetIndex_) public {
        PoolInfo storage pool = poolInfo[assetIndex_];
        UserInfo storage user = userInfo[assetIndex_][who_];

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(
                registry.UNIT_PER_SHARE()).sub(user.rewardDebt);

            user.rewardAmount = user.rewardAmount.add(pending);
        }

        uint256 updatedBalance = getUserSellerBalance(who_, assetIndex_);
        pool.amount = pool.amount.add(updatedBalance).sub(user.amount);
        user.amount = updatedBalance;

        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(registry.UNIT_PER_SHARE());

        emit Update(who_, assetIndex_);
    }

    // Claim. ---> Step 3.
    function claim(uint16 assetIndex_) external lock {
        PoolInfo storage pool = poolInfo[assetIndex_];
        UserInfo storage user = userInfo[assetIndex_][_msgSender()];

        if (pool.token == NATIVE_PLACEHOLDER) {
          _msgSender().transfer(user.rewardAmount);
        } else {
          IERC20(pool.token).safeTransfer(_msgSender(), user.rewardAmount);
        }

        emit Claim(_msgSender(), user.rewardAmount);
        user.rewardAmount = 0;
    }
}
