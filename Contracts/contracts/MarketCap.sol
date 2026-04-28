// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@prb/math/src/UD60x18.sol";

/// @title MarketCap
/// @notice Calculates and tracks market capitalization for prediction markets
/// @dev Uses PRBMath for precise decimal calculations
contract MarketCap is Ownable, ReentrancyGuard {
    using {unwrap, add, sub, mul, div, gt, gte, lt, lte} for UD60x18;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------
    error ZeroMarketId();
    error ZeroPrice();
    error ZeroSupply();
    error CapLimitExceeded();
    error InvalidCapLimit();
    error MarketNotFound();
    error InvalidThreshold();
    error InvalidBatchSize();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------
    struct MarketCapData {
        UD60x18 currentCap;           // Current market cap
        UD60x18 previousCap;          // Previous market cap for change tracking
        UD60x18 capLimit;             // Maximum allowed market cap (0 = no limit)
        UD60x18 totalSupply;          // Total token supply
        UD60x18 price;                // Current price per token
        uint256 lastUpdateTime;       // Timestamp of last update
        uint256 updateCount;          // Number of updates
        UD60x18 peakCap;              // Highest cap reached
        UD60x18 lowestCap;            // Lowest cap reached
        bool exists;                  // Market existence flag
    }

    struct CapSnapshot {
        uint256 timestamp;
        uint256 cap;
        uint256 price;
        uint256 supply;
    }

    struct BatchCapResult {
        uint256 marketId;
        uint256 cap;
        bool success;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event MarketCapCalculated(
        uint256 indexed marketId,
        uint256 currentCap,
        uint256 previousCap,
        uint256 change,
        uint256 timestamp
    );

    event CapLimitSet(
        uint256 indexed marketId,
        uint256 capLimit
    );

    event MarketCapUpdated(
        uint256 indexed marketId,
        uint256 newCap,
        uint256 price,
        uint256 supply
    );

    event CapThresholdReached(
        uint256 indexed marketId,
        uint256 cap,
        uint256 threshold,
        bool isAbove
    );

    event PeakCapReached(
        uint256 indexed marketId,
        uint256 newPeak
    );

    event BatchCapCalculated(
        uint256 successCount,
        uint256 failureCount
    );

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    /// @dev marketId => MarketCapData
    mapping(uint256 => MarketCapData) private _marketCaps;

    /// @dev List of all market IDs
    uint256[] private _marketIds;

    /// @dev marketId => threshold => enabled
    mapping(uint256 => mapping(uint256 => bool)) private _thresholds;

    /// @dev marketId => array of snapshots
    mapping(uint256 => CapSnapshot[]) private _snapshots;

    /// @dev Maximum snapshots per market
    uint256 public constant MAX_SNAPSHOTS = 100;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor() Ownable(msg.sender) {}

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @notice Calculate market capitalization for a market
    /// @param marketId The market identifier
    /// @param price Current price per token (18 decimals)
    /// @param totalSupply Total token supply (18 decimals)
    /// @return cap The calculated market cap
    function calculateMarketCap(
        uint256 marketId,
        uint256 price,
        uint256 totalSupply
    ) external nonReentrant returns (uint256 cap) {
        if (marketId == 0) revert ZeroMarketId();
        if (price == 0) revert ZeroPrice();
        if (totalSupply == 0) revert ZeroSupply();

        UD60x18 priceUD = ud(price);
        UD60x18 supplyUD = ud(totalSupply);
        UD60x18 calculatedCap = priceUD.mul(supplyUD);

        MarketCapData storage data = _marketCaps[marketId];
        
        // Check cap limit if set
        if (data.capLimit.unwrap() > 0 && calculatedCap.gt(data.capLimit)) {
            revert CapLimitExceeded();
        }

        // Initialize market if it doesn't exist
        if (!data.exists) {
            _marketIds.push(marketId);
            data.exists = true;
            data.lowestCap = calculatedCap;
            data.peakCap = calculatedCap;
        }

        // Store previous cap for change tracking
        data.previousCap = data.currentCap;
        data.currentCap = calculatedCap;
        data.price = priceUD;
        data.totalSupply = supplyUD;
        data.lastUpdateTime = block.timestamp;
        data.updateCount++;

        // Update extremes
        _updateExtremes(data, calculatedCap);

        // Check thresholds
        _checkThresholds(marketId, calculatedCap);

        // Store snapshot
        _storeSnapshot(marketId, calculatedCap.unwrap(), price, totalSupply);

        cap = calculatedCap.unwrap();

        // Calculate change
        uint256 change = data.previousCap.unwrap() > 0 
            ? (calculatedCap.gt(data.previousCap) 
                ? calculatedCap.sub(data.previousCap).unwrap()
                : data.previousCap.sub(calculatedCap).unwrap())
            : 0;

        emit MarketCapCalculated(
            marketId,
            cap,
            data.previousCap.unwrap(),
            change,
            block.timestamp
        );
    }

    /// @notice Update market cap with new price and supply
    /// @param marketId The market identifier
    /// @param price New price per token (18 decimals)
    /// @param totalSupply New total supply (18 decimals)
    function updateMarketCap(
        uint256 marketId,
        uint256 price,
        uint256 totalSupply
    ) external nonReentrant {
        if (marketId == 0) revert ZeroMarketId();
        if (price == 0) revert ZeroPrice();
        if (totalSupply == 0) revert ZeroSupply();

        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        UD60x18 priceUD = ud(price);
        UD60x18 supplyUD = ud(totalSupply);
        UD60x18 newCap = priceUD.mul(supplyUD);

        // Check cap limit if set
        if (data.capLimit.unwrap() > 0 && newCap.gt(data.capLimit)) {
            revert CapLimitExceeded();
        }

        data.previousCap = data.currentCap;
        data.currentCap = newCap;
        data.price = priceUD;
        data.totalSupply = supplyUD;
        data.lastUpdateTime = block.timestamp;

        emit MarketCapUpdated(marketId, newCap.unwrap(), price, totalSupply);
    }

    /// @notice Set a cap limit for a market
    /// @param marketId The market identifier
    /// @param capLimit Maximum allowed market cap (0 = no limit)
    function setCapLimit(uint256 marketId, uint256 capLimit) external onlyOwner {
        if (marketId == 0) revert ZeroMarketId();

        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        data.capLimit = ud(capLimit);

        emit CapLimitSet(marketId, capLimit);
    }

    /// @notice Get market cap data for a specific market
    /// @param marketId The market identifier
    /// @return currentCap Current market capitalization
    /// @return previousCap Previous market capitalization
    /// @return capLimit Maximum allowed cap (0 = no limit)
    /// @return totalSupply Total token supply
    /// @return price Current price per token
    /// @return lastUpdateTime Last update timestamp
    function getMarketCap(uint256 marketId) 
        external 
        view 
        returns (
            uint256 currentCap,
            uint256 previousCap,
            uint256 capLimit,
            uint256 totalSupply,
            uint256 price,
            uint256 lastUpdateTime
        ) 
    {
        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        return (
            data.currentCap.unwrap(),
            data.previousCap.unwrap(),
            data.capLimit.unwrap(),
            data.totalSupply.unwrap(),
            data.price.unwrap(),
            data.lastUpdateTime
        );
    }

    /// @notice Get the change in market cap
    /// @param marketId The market identifier
    /// @return change Absolute change in market cap
    /// @return isIncrease True if cap increased, false if decreased
    function getCapChange(uint256 marketId) 
        external 
        view 
        returns (uint256 change, bool isIncrease) 
    {
        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        if (data.previousCap.unwrap() == 0) {
            return (0, true);
        }

        if (data.currentCap.gt(data.previousCap)) {
            change = data.currentCap.sub(data.previousCap).unwrap();
            isIncrease = true;
        } else {
            change = data.previousCap.sub(data.currentCap).unwrap();
            isIncrease = false;
        }
    }

    /// @notice Get all market IDs
    /// @return Array of market IDs
    function getAllMarketIds() external view returns (uint256[] memory) {
        return _marketIds;
    }

    /// @notice Check if a market exists
    /// @param marketId The market identifier
    /// @return True if market exists
    function marketExists(uint256 marketId) external view returns (bool) {
        return _marketCaps[marketId].exists;
    }

    /// @notice Get total number of markets
    /// @return Number of markets
    function getMarketCount() external view returns (uint256) {
        return _marketIds.length;
    }

    /// @notice Calculate market cap without storing (view function)
    /// @param price Price per token (18 decimals)
    /// @param totalSupply Total supply (18 decimals)
    /// @return cap Calculated market cap
    function calculateCap(uint256 price, uint256 totalSupply) 
        external 
        pure 
        returns (uint256 cap) 
    {
        if (price == 0) revert ZeroPrice();
        if (totalSupply == 0) revert ZeroSupply();

        UD60x18 priceUD = ud(price);
        UD60x18 supplyUD = ud(totalSupply);
        cap = priceUD.mul(supplyUD).unwrap();
    }

    // -------------------------------------------------------------------------
    // Advanced Features
    // -------------------------------------------------------------------------

    /// @notice Batch calculate market caps for multiple markets
    /// @param marketIds Array of market IDs
    /// @param prices Array of prices
    /// @param supplies Array of supplies
    /// @return results Array of batch results
    function batchCalculateMarketCap(
        uint256[] calldata marketIds,
        uint256[] calldata prices,
        uint256[] calldata supplies
    ) external nonReentrant returns (BatchCapResult[] memory results) {
        if (marketIds.length != prices.length || marketIds.length != supplies.length) {
            revert InvalidBatchSize();
        }
        if (marketIds.length == 0 || marketIds.length > 50) {
            revert InvalidBatchSize();
        }

        results = new BatchCapResult[](marketIds.length);
        uint256 successCount = 0;
        uint256 failureCount = 0;

        for (uint256 i = 0; i < marketIds.length; i++) {
            try this.calculateMarketCap(marketIds[i], prices[i], supplies[i]) returns (uint256 cap) {
                results[i] = BatchCapResult({
                    marketId: marketIds[i],
                    cap: cap,
                    success: true
                });
                successCount++;
            } catch {
                results[i] = BatchCapResult({
                    marketId: marketIds[i],
                    cap: 0,
                    success: false
                });
                failureCount++;
            }
        }

        emit BatchCapCalculated(successCount, failureCount);
    }

    /// @notice Set a threshold alert for a market
    /// @param marketId The market identifier
    /// @param threshold The threshold value
    function setCapThreshold(uint256 marketId, uint256 threshold) external onlyOwner {
        if (marketId == 0) revert ZeroMarketId();
        if (threshold == 0) revert InvalidThreshold();

        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        _thresholds[marketId][threshold] = true;
    }

    /// @notice Remove a threshold alert
    /// @param marketId The market identifier
    /// @param threshold The threshold value
    function removeCapThreshold(uint256 marketId, uint256 threshold) external onlyOwner {
        if (marketId == 0) revert ZeroMarketId();
        
        _thresholds[marketId][threshold] = false;
    }

    /// @notice Get percentage change in market cap
    /// @param marketId The market identifier
    /// @return percentageChange Percentage change (18 decimals, e.g., 5e18 = 5%)
    /// @return isIncrease True if increased
    function getCapChangePercentage(uint256 marketId) 
        external 
        view 
        returns (uint256 percentageChange, bool isIncrease) 
    {
        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        if (data.previousCap.unwrap() == 0) {
            return (0, true);
        }

        UD60x18 hundred = ud(100e18);
        
        if (data.currentCap.gt(data.previousCap)) {
            UD60x18 change = data.currentCap.sub(data.previousCap);
            UD60x18 percentage = change.mul(hundred).div(data.previousCap);
            percentageChange = percentage.unwrap();
            isIncrease = true;
        } else {
            UD60x18 change = data.previousCap.sub(data.currentCap);
            UD60x18 percentage = change.mul(hundred).div(data.previousCap);
            percentageChange = percentage.unwrap();
            isIncrease = false;
        }
    }

    /// @notice Get peak and lowest caps for a market
    /// @param marketId The market identifier
    /// @return peakCap Highest cap reached
    /// @return lowestCap Lowest cap reached
    function getCapExtremes(uint256 marketId) 
        external 
        view 
        returns (uint256 peakCap, uint256 lowestCap) 
    {
        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        peakCap = data.peakCap.unwrap();
        lowestCap = data.lowestCap.unwrap();
    }

    /// @notice Get update count for a market
    /// @param marketId The market identifier
    /// @return count Number of updates
    function getUpdateCount(uint256 marketId) external view returns (uint256 count) {
        MarketCapData storage data = _marketCaps[marketId];
        if (!data.exists) revert MarketNotFound();

        count = data.updateCount;
    }

    /// @notice Get historical snapshots for a market
    /// @param marketId The market identifier
    /// @return snapshots Array of historical snapshots
    function getSnapshots(uint256 marketId) 
        external 
        view 
        returns (CapSnapshot[] memory snapshots) 
    {
        return _snapshots[marketId];
    }

    /// @notice Get latest snapshot for a market
    /// @param marketId The market identifier
    /// @return snapshot Latest snapshot
    function getLatestSnapshot(uint256 marketId) 
        external 
        view 
        returns (CapSnapshot memory snapshot) 
    {
        CapSnapshot[] storage snaps = _snapshots[marketId];
        if (snaps.length == 0) {
            return CapSnapshot(0, 0, 0, 0);
        }
        return snaps[snaps.length - 1];
    }

    /// @notice Compare two markets by cap
    /// @param marketId1 First market ID
    /// @param marketId2 Second market ID
    /// @return difference Absolute difference in caps
    /// @return market1IsLarger True if market1 has larger cap
    function compareMarketCaps(uint256 marketId1, uint256 marketId2) 
        external 
        view 
        returns (uint256 difference, bool market1IsLarger) 
    {
        MarketCapData storage data1 = _marketCaps[marketId1];
        MarketCapData storage data2 = _marketCaps[marketId2];
        
        if (!data1.exists) revert MarketNotFound();
        if (!data2.exists) revert MarketNotFound();

        if (data1.currentCap.gt(data2.currentCap)) {
            difference = data1.currentCap.sub(data2.currentCap).unwrap();
            market1IsLarger = true;
        } else {
            difference = data2.currentCap.sub(data1.currentCap).unwrap();
            market1IsLarger = false;
        }
    }

    /// @notice Get total market cap across all markets
    /// @return totalCap Sum of all market caps
    function getTotalMarketCap() external view returns (uint256 totalCap) {
        UD60x18 total = ud(0);
        
        for (uint256 i = 0; i < _marketIds.length; i++) {
            MarketCapData storage data = _marketCaps[_marketIds[i]];
            total = total.add(data.currentCap);
        }
        
        totalCap = total.unwrap();
    }

    /// @notice Get markets sorted by cap (top N)
    /// @param limit Maximum number of markets to return
    /// @return marketIds Array of market IDs sorted by cap (descending)
    /// @return caps Array of corresponding caps
    function getTopMarketsByCap(uint256 limit) 
        external 
        view 
        returns (uint256[] memory marketIds, uint256[] memory caps) 
    {
        uint256 length = _marketIds.length;
        if (limit > length) limit = length;
        if (limit == 0) return (new uint256[](0), new uint256[](0));

        // Create arrays for sorting
        uint256[] memory allIds = new uint256[](length);
        uint256[] memory allCaps = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            allIds[i] = _marketIds[i];
            allCaps[i] = _marketCaps[_marketIds[i]].currentCap.unwrap();
        }

        // Simple bubble sort for top N (good enough for small arrays)
        for (uint256 i = 0; i < length - 1; i++) {
            for (uint256 j = 0; j < length - i - 1; j++) {
                if (allCaps[j] < allCaps[j + 1]) {
                    // Swap caps
                    (allCaps[j], allCaps[j + 1]) = (allCaps[j + 1], allCaps[j]);
                    // Swap ids
                    (allIds[j], allIds[j + 1]) = (allIds[j + 1], allIds[j]);
                }
            }
        }

        // Return top N
        marketIds = new uint256[](limit);
        caps = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            marketIds[i] = allIds[i];
            caps[i] = allCaps[i];
        }
    }

    // -------------------------------------------------------------------------
    // Internal functions
    // -------------------------------------------------------------------------

    /// @dev Check thresholds and emit events
    function _checkThresholds(uint256 marketId, UD60x18 cap) internal {
        uint256 capValue = cap.unwrap();
        
        // Check common thresholds
        uint256[5] memory commonThresholds = [
            1000e18,   // 1k
            10000e18,  // 10k
            100000e18, // 100k
            1000000e18, // 1M
            10000000e18 // 10M
        ];

        for (uint256 i = 0; i < commonThresholds.length; i++) {
            if (_thresholds[marketId][commonThresholds[i]]) {
                if (capValue >= commonThresholds[i]) {
                    emit CapThresholdReached(marketId, capValue, commonThresholds[i], true);
                } else {
                    emit CapThresholdReached(marketId, capValue, commonThresholds[i], false);
                }
            }
        }
    }

    /// @dev Update peak and lowest caps
    function _updateExtremes(MarketCapData storage data, UD60x18 newCap) internal {
        // Update peak
        if (data.peakCap.unwrap() == 0 || newCap.gt(data.peakCap)) {
            data.peakCap = newCap;
            emit PeakCapReached(data.updateCount, newCap.unwrap());
        }

        // Update lowest
        if (data.lowestCap.unwrap() == 0 || newCap.lt(data.lowestCap)) {
            data.lowestCap = newCap;
        }
    }

    /// @dev Store snapshot
    function _storeSnapshot(uint256 marketId, uint256 cap, uint256 price, uint256 supply) internal {
        CapSnapshot[] storage snaps = _snapshots[marketId];
        
        // If at max, remove oldest
        if (snaps.length >= MAX_SNAPSHOTS) {
            for (uint256 i = 0; i < snaps.length - 1; i++) {
                snaps[i] = snaps[i + 1];
            }
            snaps.pop();
        }

        snaps.push(CapSnapshot({
            timestamp: block.timestamp,
            cap: cap,
            price: price,
            supply: supply
        }));
    }
}
