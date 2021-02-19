// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IPolicy.sol";


// This contract is owned by Timelock.
contract Buyer is IBuyer, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    // The base of premium rate and accWeeklyCost
    uint256 constant PREMIUM_BASE = 1e6;

    IERC20 public baseToken;  // By default it's USDC
    IAssetManager public assetManager;

    struct UserInfo {
        uint256 balance;
        uint256 weekCovered;  // The week that the use was last covered
        uint256 weekUpdated;  // The week that balance was updated
    }

    mapping(address => UserInfo) public userInfoMap;

    // Tracks user's current covered amount of each asset.
    // user => assetIndex => coveredAmount
    mapping(address => mapping(uint256 => uint256)) public override currentCoveredAmount;

    address[] public currentBuyers;
    // indices + 1
    mapping(address => uint256) public currentBuyerIndices;

    constructor (IERC20 baseToken_, IAssetManager assetManager_) public {
        baseToken = baseToken_;
        assetManager = assetManager_;
    }

    function setBaseToken(IERC20 baseToken_) public onlyOwner {
        baseToken = baseToken_;
    }

    function setAssetManager(IAssetManager assetManager_) public onlyOwner {
        assetManager = assetManager_;
    }

    function _insertBuyer(address buyer_) internal {
        uint256 indexPlusOne = currentBuyerIndices[buyer_];
        if (indexPlusOne > 0) {
            currentBuyers[indexPlusOne - 1] = buyer_;
        } else {
            currentBuyers.push(buyer_);
            currentBuyerIndices[buyer_] = currentBuyers.length;
        }
    }

    function _removeBuyer(address buyer_) internal {
        uint256 indexPlusOne = currentBuyerIndices[buyer_];
        if (indexPlusOne > 0) {
            currentBuyers[indexPlusOne - 1] = currentBuyers[currentBuyers.length - 1];
            currentBuyerIndices[currentBuyers[indexPlusOne - 1]] = indexPlusOne;
            currentBuyerIndices[buyer_] = 0;
            currentBuyers.pop();
        }
    }

    function getAccPremium(address who_, uint256 _week) public view returns(uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < assetManager.getAssetLength(); ++i) {
            if (currentCoveredAmount[who_][i] > 0) {
                uint256 costPerShare = IPolicy(assetManager.getAssetPolicy(i)).accWeeklyCost(_week);

                require(costPerShare > 0, "Policy not up to date");

                total = total.add(costPerShare.mul(currentCoveredAmount[who_][i]).div(PREMIUM_BASE));
            }
        }

        return total;
    }

    function findWeekCovered(address who_) public override view returns(uint256, uint256) {
        if (userInfoMap[who_].weekUpdated == 0) {
            return (0, 0);
        }

        uint256 left = userInfoMap[who_].weekUpdated;
        uint256 right = now.div(7 days);
        uint256 leftAccPremium = getAccPremium(who_, left);
        uint256 initialAccPremium = leftAccPremium;
        uint256 rightAccPremium = getAccPremium(who_, right);

        if (rightAccPremium.sub(initialAccPremium) <= userInfoMap[who_].balance) {
            return (right, rightAccPremium);
        }

        for (uint256 i = 0; ; ++i) {
            require(i < 100, "2^100 weeks from now? Earth will explode.");

            if (left >= right) {
                break;
            }

            uint256 mid = (left + right).div(2);
            uint256 midAccPremium = getAccPremium(who_, mid);

            if (midAccPremium.sub(initialAccPremium) > userInfoMap[who_].balance) {
                right = mid;
                rightAccPremium = midAccPremium;
            } else {
                left = mid;
                leftAccPremium = midAccPremium;
            }
        }

        return (left, leftAccPremium);
    }

    // This function may time out if someone didn't operate for long enough.
    function getRealBalance(address who_) public view returns(uint256) {
        if (userInfoMap[who_].weekUpdated == 0) {
            return userInfoMap[who_].balance;
        }

        (, uint256 lastAccPremium) = findWeekCovered(who_);
        uint256 cost = lastAccPremium.sub(getAccPremium(who_, userInfoMap[who_].weekUpdated));
        require(userInfoMap[who_].balance >= cost, "not enough balance");

        return userInfoMap[who_].balance.sub(cost);
    }

    function update(address who_) public {
        if (userInfoMap[who_].weekUpdated == 0) {
            userInfoMap[who_].weekUpdated = now.div(7 days);
            return;
        }

        (uint256 lastWeekCovered, uint256 lastAccPremium) = findWeekCovered(who_);
        uint256 cost = lastAccPremium.sub(getAccPremium(who_, userInfoMap[who_].weekUpdated));
        require(userInfoMap[who_].balance >= cost, "not enough balance");

        userInfoMap[who_].balance = userInfoMap[who_].balance.sub(cost);
        userInfoMap[who_].weekCovered = lastWeekCovered;
        userInfoMap[who_].weekUpdated = now.div(7 days);  // This week.

        if (userInfoMap[who_].weekCovered == userInfoMap[who_].weekUpdated) {
            _insertBuyer(msg.sender);
        } else {
            _removeBuyer(msg.sender);
        }
    }

    function processAllBuyers() public {
    }

    // Deposit
    function deposit(uint256 amount_) external {
        update(msg.sender);

        baseToken.safeTransferFrom(msg.sender, address(this), amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.add(amount_);
    }

    // Withdraw
    function withdraw(uint256 amount_) external {
        update(msg.sender);

        require(userInfoMap[msg.sender].balance > amount_, "not enough balance");
        baseToken.safeTransfer(msg.sender, amount_);
        userInfoMap[msg.sender].balance = userInfoMap[msg.sender].balance.sub(amount_);
    }

    function subscribe(uint256 assetIndex_, uint256 amount_) external {
        currentCoveredAmount[msg.sender][assetIndex_] = currentCoveredAmount[msg.sender][assetIndex_].add(amount_);
    }

    function unsubscribe(uint256 assetIndex_, uint256 amount_) external {
        currentCoveredAmount[msg.sender][assetIndex_] = currentCoveredAmount[msg.sender][assetIndex_].sub(amount_);
    }
}
