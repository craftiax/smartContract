// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./EventTicketBase.sol";
import "@prb/math/src/Common.sol";

contract EventTicketManager is EventTicketBase {
    // Struct to hold event creation parameters
    struct EventCreationParams {
        string eventId; // Unique identifier for the event
        string name; // Name of the event
        string description; // Description of the event
        uint256 saleEndTime; // End time of ticket sales
        string[] tierIds; // Array of tier IDs for the event
        uint256[] prices; // Array of prices for each tier
        uint256[] maxQuantities; // Array of maximum quantities for each tier
        uint256[] maxTicketsPerUser; // Array of maximum tickets per user for each tier
        PaymentCurrency currency; // Currency used for the event (ETH or USD)
        string event_organiser_username; // Username of the event organiser
    }

    // Add array to track all event IDs
    string[] private allEventIds;
    
    // Mapping to track if an event ID exists
    mapping(string => bool) private eventIdExists;

    // Rate limiting
    uint256 public RATE_LIMIT_WINDOW;
    uint256 public MAX_MINTS_PER_WINDOW;
    uint256 public MIN_TIME_BETWEEN_MINTS;

    // Minimum commission in basis points (0.5%)
    uint256 public constant MIN_COMMISSION = 50;
    // Maximum commission change per update in basis points (2%)
    uint256 public constant MAX_COMMISSION_CHANGE = 200;

    // Add new events
    event EventDeactivated(string eventId);
    event TicketBurned(string eventId, string tierId, uint256 tokenId, address owner);

    constructor(address _usdToken) EventTicketBase(_usdToken) {
        platformCommissionAddress = 0x984D8DD1De91e00C0DAa5A34a0CC78C344012F1A;
        _initializeRateLimits();
    }

    function _initializeRateLimits() private {
        RATE_LIMIT_WINDOW = 1 hours;
        MAX_MINTS_PER_WINDOW = 2000;
        MIN_TIME_BETWEEN_MINTS = 3 seconds;
    }

    // Helper function to validate event creation parameters
    function _validateEventParams(EventCreationParams memory params) internal view {
        require(params.prices.length == params.maxQuantities.length && 
                params.prices.length == params.tierIds.length && 
                params.prices.length == params.maxTicketsPerUser.length, 
                "Invalid tier data");
        require(params.prices.length > 0 && params.prices.length <= MAX_TIERS, "Invalid tier count");
        require(block.timestamp < params.saleEndTime, "Sale end time must be in future");

        for (uint256 i = 0; i < params.tierIds.length; i++) {
            require(bytes(params.tierIds[i]).length > 0, "Invalid tier ID");
            require(params.prices[i] >= MIN_PRICE && params.prices[i] <= MAX_PRICE, "Invalid price");
            require(params.maxQuantities[i] > 0, "Invalid quantity");
            require(params.maxTicketsPerUser[i] > 0 && params.maxTicketsPerUser[i] <= params.maxQuantities[i], 
                    "Invalid max tickets per user");
        }
    }

    // Helper function to create event tiers
    function _createEventTiers(Event storage event_, EventCreationParams memory params) internal {
        for (uint256 i = 0; i < params.tierIds.length; i++) {
            EventTier storage newTier = event_.tiers[params.tierIds[i]];
            newTier.price = params.prices[i];
            newTier.maxQuantity = params.maxQuantities[i];
            newTier.soldCount = 0;
            newTier.isActive = true;
            newTier.maxTicketsPerUser = params.maxTicketsPerUser[i];
            event_.tierIds.push(params.tierIds[i]);
        }
    }

    function createEvent(EventCreationParams memory params) external whenNotPaused {
        require(!eventExists(params.eventId), "Event already exists");
        
        // Validate parameters
        _validateEventParams(params);

        // Create event
        Event storage newEvent = events[params.eventId];
        newEvent.name = params.name;
        newEvent.description = params.description;
        newEvent.saleStartTime = block.timestamp;
        newEvent.saleEndTime = params.saleEndTime;
        newEvent.organizer = msg.sender;
        newEvent.status = EventStatus.PUBLISHED;
        newEvent.currency = params.currency;
        newEvent.isActive = true;
        newEvent.isRefundable = false;
        newEvent.organizer_username = params.event_organiser_username;

        // Create tiers
        _createEventTiers(newEvent, params);

        // Add event ID to tracking
        if (!eventIdExists[params.eventId]) {
            allEventIds.push(params.eventId);
            eventIdExists[params.eventId] = true;
        }

        emit EventCreated(params.eventId, msg.sender, params.name);
    }

    function setEventOrganizerUsername(string memory eventId, string memory username) external {
        Event storage event_ = events[eventId];
        require(event_.organizer == msg.sender, "Not event organizer");
        require(bytes(username).length > 0, "Username required");
        event_.organizer_username = username;
    }

    function mintTicket(
        string memory eventId,
        string memory tierId,
        address recipient
    ) external payable nonReentrant whenNotPaused {
        Event storage event_ = events[eventId];
        require(event_.isActive, "Event not active");
        require(isEventActive(event_), "Event not in active timeframe");

        EventTier storage tier = event_.tiers[tierId];
        require(tier.isActive, "Tier not active");
        require(tier.soldCount < tier.maxQuantity, "Tier sold out");
        require(tier.userMintedCount[recipient] < tier.maxTicketsPerUser, "Exceeds max tickets per user");

        uint256 tokenId = uint256(keccak256(abi.encode(eventId, tierId)));
        
        // Handle free tickets first
        if (tier.price == 0) {
            _mint(recipient, tokenId, 1, "");
            tier.soldCount++;
            tier.userMintedCount[recipient]++;
            emit TicketMinted(eventId, tierId, recipient, 0);
            return;
        }
        
        if (event_.currency == PaymentCurrency.USD) {
            uint256 scaledPrice = _scaleAmount(tier.price);
            require(scaledPrice > 0, "Scaled amount too small");
            require(_processPayment(scaledPrice, PaymentCurrency.USD, msg.sender), "USDC payment failed");
            _handleCommissionAndPayment(event_, scaledPrice, PaymentCurrency.USD);
        } else {
            require(msg.value == tier.price, "Incorrect ETH amount");
            _handleCommissionAndPayment(event_, msg.value, PaymentCurrency.ETH);
        }

        _mint(recipient, tokenId, 1, "");
        tier.soldCount++;
        tier.userMintedCount[recipient]++;

        emit TicketMinted(eventId, tierId, recipient, tier.price);
    }

    function _handleCommissionAndPayment(
        Event storage event_,
        uint256 scaledAmount,
        PaymentCurrency currency
    ) internal override {
        super._handleCommissionAndPayment(event_, scaledAmount, currency);
    }

    // View functions
    function getEventDetails(string calldata eventId) external view returns (
        address creator,
        bool isActive,
        uint256 totalTiers,
        string memory name,
        PaymentCurrency currency,
        uint256 saleEndTime
    ) {
        Event storage event_ = events[eventId];
        return (
            event_.organizer,
            event_.isActive,
            event_.tierIds.length,
            event_.name,
            event_.currency,
            event_.saleEndTime
        );
    }

    function getEventDescription(string calldata eventId) external view returns (string memory) {
        return events[eventId].description;
    }

    function getEventSaleStartTime(string calldata eventId) external view returns (uint256) {
        return events[eventId].saleStartTime;
    }

    function getEventTierDetails(
        string memory eventId,
        string memory tierId
    ) external view returns (
        uint256 price,
        uint256 maxQuantity,
        uint256 soldCount,
        bool isActive
    ) {
        Event storage event_ = events[eventId];
        EventTier storage tier = event_.tiers[tierId];
        return (
            tier.price,
            tier.maxQuantity,
            tier.soldCount,
            tier.isActive
        );
    }

    function updateTierPrice(
        string memory eventId,
        string memory tierId,
        uint256 newPrice
    ) external {
        Event storage event_ = events[eventId];
        require(event_.organizer == msg.sender, "Not event organizer");
        require(event_.isActive, "Event not active");
        
        EventTier storage tier = event_.tiers[tierId];
        require(tier.isActive, "Tier not active");
        tier.price = newPrice;
    }

    function eventExists(string memory eventId) public view returns (bool) {
        return events[eventId].organizer != address(0);
    }

    // Admin functions
    function withdrawPlatformFees(address payable recipient) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        
        uint256 ethBalance = address(this).balance;
        uint256 usdBalance = usdToken.balanceOf(address(this));
        
        if (ethBalance > 0) {
            (bool success, ) = recipient.call{value: ethBalance}("");
            require(success, "ETH transfer failed");
        }
        
        if (usdBalance > 0) {
            require(usdToken.transfer(recipient, usdBalance), "USDC transfer failed");
        }
        
        emit FeesWithdrawn(recipient, ethBalance, usdBalance);
    }

    function updateCommissionPercentage(uint256 newPercentage) external onlyOwner {
        require(newPercentage >= MIN_COMMISSION, "Commission too low");
        require(newPercentage <= 1000, "Commission cannot exceed 10%");
        
        // Check maximum change allowed
        uint256 change = newPercentage > COMMISSION_PERCENTAGE ? 
            newPercentage - COMMISSION_PERCENTAGE : 
            COMMISSION_PERCENTAGE - newPercentage;
        require(change <= MAX_COMMISSION_CHANGE, "Change too large");

        uint256 oldPercentage = COMMISSION_PERCENTAGE;
        COMMISSION_PERCENTAGE = newPercentage;
        
        emit CommissionUpdated(oldPercentage, newPercentage);
    }

    function updatePlatformCommissionAddress(address newAddress) external override onlyOwner {
        require(newAddress != address(0), "Invalid address");
        address oldAddress = platformCommissionAddress;
        platformCommissionAddress = newAddress;
        emit PlatformAddressUpdated(oldAddress, newAddress);
    }

    // Add a view function to check user's minted tickets count
    function getUserMintedCount(
        string memory eventId,
        string memory tierId,
        address user
    ) external view returns (uint256 mintedCount, uint256 maxAllowed) {
        Event storage event_ = events[eventId];
        EventTier storage tier = event_.tiers[tierId];
        return (tier.userMintedCount[user], tier.maxTicketsPerUser);
    }

    function burnTicket(
        string memory eventId,
        string memory tierId
    ) external nonReentrant {
        Event storage event_ = events[eventId];
        EventTier storage tier = event_.tiers[tierId];
        uint256 tokenId = uint256(keccak256(abi.encode(eventId, tierId)));
        
        require(balanceOf(msg.sender, tokenId) > 0, "No ticket owned");
        
        _burn(msg.sender, tokenId, 1);
        tier.soldCount--;
        tier.userMintedCount[msg.sender]--;
        
        emit TicketBurned(eventId, tierId, tokenId, msg.sender);
    }

    function deactivateEvent(string memory eventId) external {
        Event storage event_ = events[eventId];
        require(msg.sender == event_.organizer || msg.sender == owner(), "Not authorized");
        require(event_.isActive, "Event already inactive");
        
        event_.isActive = false;
        emit EventDeactivated(eventId);
    }

    // Function to get all event IDs
    function getAllEventIds() external view returns (string[] memory) {
        return allEventIds;
    }

    // Function to get event identifiers
    function getEventIdentifiers(string calldata eventId) external view returns (
        address creator,
        bool isActive,
        uint256 totalTiers
    ) {
        Event storage event_ = events[eventId];
        return (
            event_.organizer,
            event_.isActive,
            event_.tierIds.length
        );
    }

    // Function to get event metadata
    function getEventMetadata(string calldata eventId) external view returns (
        string memory name,
        string memory description,
        PaymentCurrency currency
    ) {
        Event storage event_ = events[eventId];
        return (
            event_.name,
            event_.description,
            event_.currency
        );
    }

    // Function to get event time details
    function getEventTimeDetails(string calldata eventId) external view returns (
        uint256 saleStartTime,
        uint256 saleEndTime
    ) {
        Event storage event_ = events[eventId];
        return (
            event_.saleStartTime,
            event_.saleEndTime
        );
    }
} 