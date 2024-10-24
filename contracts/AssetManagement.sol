// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// Uncomment this line to use console.log
// import "hardhat/console.sol";
import "./interfaces/ISupraSValueFeed.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AssetManagement is Ownable, ReentrancyGuard {
    uint immutable MAX_INT =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    uint private poolIdx;
    ISupraSValueFeed sValueFeed;
    uint private fee; // 100000/100000

    struct Pool {
        uint64[] tokenPairIndexes; // 0,1,2,3,4,5
        uint[] tokenWeight; // 100/100
        uint totalDeposit;
        uint createdAt;
        User[] users;
        address creator;
        bool isModified;
    }

    struct User {
        address depositor;
        uint amount;
        uint depositAt;
        uint[] assetPrice;
    }

    mapping(uint => Pool) private pools;

    event PoolCreated(uint poolId, address owner);
    event Deposited(uint poolId, address who, uint amount);
    event Withdrawn(uint poolId, address who, uint amount);
    event FeeUpdated(uint amount);
    event PoolUpdated(uint poolIdx);

    error InvalidAddress();
    error InsuffecientFund();
    error NotDeposited();
    error CannotWithdraw();
    error SentFailed();
    error NotCreator();
    error Unmodifiable();

    constructor(
        address _newSValueFeed,
        address _tokenForDeposit
    ) Ownable(msg.sender) {
        require(_newSValueFeed != address(0));
        sValueFeed = ISupraSValueFeed(_newSValueFeed);
        poolIdx = 0;
        fee = 1000;
    }

    function calculateDepositResult(
        uint64[] memory tokenPairIndexesInput,
        uint[] memory tokenWeightInput,
        uint[] memory oldPriceOfToken,
        uint initialAmount
    ) public returns (uint newValue, uint percent, bool isLoss, uint[] memory) {
        newValue = initialAmount;
        uint[] memory newPrice;
        for (uint index = 0; index < tokenPairIndexesInput.length; index++) {
            uint[4] memory newTokenPriceResults = fetchPrice(
                tokenPairIndexesInput[index]
            );
            if (newTokenPriceResults[3] > oldPriceOfToken[index]) {
                // profit for each token component
                newValue +=
                    (((newTokenPriceResults[3] - oldPriceOfToken[index]) *
                        initialAmount) * tokenWeightInput[index]) /
                    oldPriceOfToken[index];
            } else {
                // loss for each token component
                newValue -=
                    (((oldPriceOfToken[index] - newTokenPriceResults[3]) *
                        initialAmount) * tokenWeightInput[index]) /
                    oldPriceOfToken[index];
            }
            newPrice[index] = newTokenPriceResults[3];
        }
        if (newValue > initialAmount) {
            isLoss = false;
            percent = ((newValue - initialAmount) * 100) / initialAmount;
        } else {
            isLoss = true;
            percent = ((initialAmount - newValue) * 100) / initialAmount;
        }
        return (newValue, percent, isLoss, newPrice);
    }

    function createPool(
        uint64[] calldata tokenPairIndexesInput,
        uint[] calldata tokenWeightInput,
        bool isModifiedInput
    ) external {
        // create new pool
        uint poolIdxMem = poolIdx;
        Pool storage pool = pools[poolIdxMem];
        pool.tokenPairIndexes = tokenPairIndexesInput;
        pool.tokenWeight = tokenWeightInput;
        pool.isModified = isModifiedInput;
        pool.creator = msg.sender;
        pool.totalDeposit = 0;

        poolIdx = poolIdxMem + 1;

        emit PoolCreated(poolIdxMem, msg.sender);
    }

    function depositPool(uint poolIdxInput) external payable nonReentrant {
        Pool storage pool = pools[poolIdxInput];
        Pool memory poolMem = pool;

        User[] memory users = poolMem.users;

        uint valueDeposit = 0;
        uint[] memory assetPrice;

        uint depositFee = msg.value / fee;

        uint depositedUserIndex = MAX_INT;
        for (uint index = 0; index < users.length; index++) {
            if (poolMem.users[index].depositor == msg.sender) {
                (
                    uint newValue,
                    uint percent,
                    bool isLoss,
                    uint[] memory newPrice
                ) = calculateDepositResult(
                        poolMem.tokenPairIndexes,
                        poolMem.tokenWeight,
                        poolMem.users[index].assetPrice,
                        poolMem.users[index].amount
                    );
                valueDeposit = newValue;
                assetPrice = newPrice;
                depositedUserIndex = index;
            }
        }

        pool.totalDeposit = valueDeposit + msg.value - depositFee;

        User memory user;
        user.amount = valueDeposit + msg.value - depositFee;
        user.depositAt = block.timestamp;
        user.depositor = msg.sender;
        user.assetPrice = assetPrice;

        // save to storage
        pools[poolIdxInput] = pool;
        if (depositedUserIndex == MAX_INT) {
            // new deposit
            pools[poolIdxInput].users.push(user);
        } else {
            // deposited before
            pools[poolIdxInput].users[depositedUserIndex] = user;
        }

        emit Deposited(poolIdxInput, msg.sender, msg.value);
    }

    function withdraw(
        uint poolIdxInput,
        uint amountInput
    ) external nonReentrant {
        Pool storage pool = pools[poolIdxInput];
        if (pool.totalDeposit < amountInput) {
            revert InsuffecientFund();
        }
        uint withdrawFee = amountInput / fee;
        User[] memory users = pool.users;
        for (uint index = 0; index < users.length; index++) {
            // find depositor info that match sender
            if (pool.users[index].depositor == msg.sender) {
                (
                    uint newValue,
                    uint percent,
                    bool isLoss,
                    uint[] memory newPrice
                ) = calculateDepositResult(
                        pool.tokenPairIndexes,
                        pool.tokenWeight,
                        pool.users[index].assetPrice,
                        pool.users[index].amount
                    );

                if (newValue < amountInput) {
                    revert CannotWithdraw();
                } else {
                    pool.totalDeposit -= (amountInput - withdrawFee);
                    pool.users[index].amount =
                        newValue -
                        (amountInput - withdrawFee);
                    pool.users[index].assetPrice = newPrice;

                    if (
                        (msg.sender == pool.creator) ||
                        (msg.sender != pool.creator && isLoss == true)
                    ) {
                        (bool sent, bytes memory data) = msg.sender.call{
                            value: (amountInput - withdrawFee)
                        }("");
                        if (sent == false) {
                            revert SentFailed();
                        }
                    } else {
                        // share 10% profit to creator
                        uint paybackAmount = amountInput - withdrawFee;
                        uint share = paybackAmount / 10;
                        (bool sentUser, ) = msg.sender.call{
                            value: paybackAmount - share
                        }("");
                        if (sentUser == false) {
                            revert SentFailed();
                        }
                        (bool sentCreator, ) = pool.creator.call{value: share}(
                            ""
                        );
                        if (sentCreator == false) {
                            revert SentFailed();
                        }
                    }
                }

                // save to storage
                pools[poolIdxInput] = pool;

                emit Withdrawn(poolIdx, msg.sender, amountInput);
                return;
            }
        }
        revert NotDeposited();
    }

    function updatePool(
        uint poolIdx,
        uint64[] calldata tokenPairIndexesInput,
        uint[] calldata tokenWeightInput
    ) external {
        Pool storage pool = pools[poolIdx];
        Pool memory poolMem = pool;
        if (poolMem.isModified == false) {
            revert Unmodifiable();
        }
        if (poolMem.creator != msg.sender) {
            revert NotCreator();
        }
        for (uint index = 0; index < poolMem.users.length; index++) {
            // update value for every user user this pool
            (
                uint newValue,
                uint percent,
                bool isLoss,
                uint[] memory newPrice
            ) = calculateDepositResult(
                    poolMem.tokenPairIndexes,
                    poolMem.tokenWeight,
                    poolMem.users[index].assetPrice,
                    poolMem.users[index].amount
                );

            pool.users[index].amount = newValue;
            pool.users[index].assetPrice = newPrice;
        }

        pool.tokenPairIndexes = tokenPairIndexesInput;
        pool.tokenWeight = tokenWeightInput;

        emit PoolUpdated(poolIdx);
    }

    function changeFee(uint feeInput) external onlyOwner {
        fee = feeInput;
        emit FeeUpdated(feeInput);
    }

    function getPoolInfo(uint poolIdx) external returns (Pool memory) {
        return pools[poolIdx];
    }

    function getFee() external returns (uint) {
        return fee;
    }

    function fetchPrice(uint64 value) private view returns (uint[4] memory) {
        (bytes32 data, ) = sValueFeed.getSvalue(value);
        return unpack(data);
    }

    function unpack(bytes32 data) private pure returns (uint[4] memory) {
        uint[4] memory info;

        info[0] = bytesToUint256(abi.encodePacked(data >> 192)); // round
        info[1] = bytesToUint256(abi.encodePacked((data << 64) >> 248)); // decimal
        info[2] = bytesToUint256(abi.encodePacked((data << 72) >> 192)); // timestamp
        info[3] = bytesToUint256(abi.encodePacked((data << 136) >> 160)); // price

        return info;
    }

    function bytesToUint256(
        bytes memory _bs
    ) private pure returns (uint value) {
        require(_bs.length == 32, "bytes length is not 32.");
        assembly {
            value := mload(add(_bs, 0x20))
        }
    }
}
