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
        uint16 assetIndex;
        address token;  // token as bonus.
        uint256 amount;
        uint256 accRewardPerShare;
    }

    // pid => PoolInfo
    PoolInfo[] public poolInfo;

    struct UserInfo {
        uint256 amount;
        uint256 rewardAmount;
        uint256 rewardDebt; // Reward debt.
    }

    // pid => who => UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event AddPool(uint256 pid_, uint16 assetIndex, address token_);
    event AddBonus(address indexed user_, uint256 pid_, uint256 amount_);
    event Update(address indexed user_, uint256 pid_);
    event Claim(address indexed user_, uint256 pid_, uint256 amount_);

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _msgSender() internal override(Context, BaseRelayRecipient) view returns (address payable) {
        return BaseRelayRecipient._msgSender();
    }

    function _trustedForwarder() internal override view returns(address) {
        return registry.trustedForwarder();
    }

    function addPool(uint16 assetIndex_, address token_) external onlyOwner {
        PoolInfo memory info;
        info.assetIndex = assetIndex_;
        info.token = token_;
        poolInfo.push(info);
        emit AddPool(poolInfo.length - 1, assetIndex_, token_);
    }

    // Adds bonus --> Step 2.
    function addBonus(uint256 pid_, uint256 amount_) external lock {
        PoolInfo storage pool = poolInfo[pid_];

        require(pool.token != address(0), "Token not set");
        require(pool.amount > 0, "Pool amount non-zero");

        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount_);

        pool.accRewardPerShare = pool.accRewardPerShare.add(
            amount_.mul(registry.UNIT_PER_SHARE()).div(pool.amount));

        emit AddBonus(msg.sender, pid_, amount_);
    }

    // Adds bonus --> Step 2.
    function addBonusNative(uint256 pid_, uint256 amount_) external payable lock {
        PoolInfo storage pool = poolInfo[pid_];

        require(pool.token == NATIVE_PLACEHOLDER, "Token not native");
        require(pool.amount > 0, "Pool amount non-zero");
        require(msg.value == amount_, "Amount not sent");

        pool.accRewardPerShare = pool.accRewardPerShare.add(
            amount_.mul(registry.UNIT_PER_SHARE()).div(pool.amount));

        emit AddBonus(msg.sender, pid_, amount_);
    }

    function getUserSellerBalance(address who_, uint256 pid_) public view returns(uint256) {
        PoolInfo storage pool = poolInfo[pid_];

        if (!ISeller(registry.seller()).userBasket(who_, pool.assetIndex)) {
            return 0;
        }

        (uint256 currentBalance, ) = ISeller(registry.seller()).userBalance(
            who_, IAssetManager(registry.assetManager()).getAssetCategory(pool.assetIndex));
        return currentBalance;
    }

    function massUpdate(address who_, uint256[] memory pidArray_) external {
        for (uint256 i = 0; i < pidArray_.length; ++i) {
            update(who_, pidArray_[i]);
        }
    }

    // Every week update. ---> Step 1.
    function update(address who_, uint256 pid_) public {
        PoolInfo storage pool = poolInfo[pid_];
        UserInfo storage user = userInfo[pid_][who_];

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(
                registry.UNIT_PER_SHARE()).sub(user.rewardDebt);

            user.rewardAmount = user.rewardAmount.add(pending);
        }

        uint256 updatedBalance = getUserSellerBalance(who_, pid_);
        pool.amount = pool.amount.add(updatedBalance).sub(user.amount);
        user.amount = updatedBalance;

        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(registry.UNIT_PER_SHARE());

        emit Update(who_, pid_);
    }

    // Claim. ---> Step 3.
    function claim(uint256 pid_) external lock {
        PoolInfo storage pool = poolInfo[pid_];
        UserInfo storage user = userInfo[pid_][_msgSender()];

        if (pool.token == NATIVE_PLACEHOLDER) {
          (bool success, ) = _msgSender().call.value(user.rewardAmount)("");
          require(success, "Transfer failed.");
        } else {
          IERC20(pool.token).safeTransfer(_msgSender(), user.rewardAmount);
        }

        emit Claim(_msgSender(), pid_, user.rewardAmount);
        user.rewardAmount = 0;
    }
}
