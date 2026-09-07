// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract SpendingLimitModule {

    uint256 constant MODULE_TYPE_VALIDATOR = 1;

    uint256 constant MAX_CHANGE_PERCENT = 50;

    address public owner;
    address public agent;

    uint256 public maxPerTransaction;   
    uint256 public weeklyLimit;        


    mapping(uint256 => uint256) public dailySpend;

    uint256 public lastReportedDay;

    address public smartAccount;

    event LimitsUpdated(uint256 maxPerTransaction, uint256 weeklyLimit);
    event DayReported(uint256 dayIndex, uint256 amount, uint256 runningWeeklyTotal);
    event AgentUpdated(address newAgent);

    modifier onlyOwner() {
        require(msg.sender == owner, "Doar owner-ul poate face asta");
        _;
    }

    modifier onlyAgent() {
        require(msg.sender == agent, "Doar agentul poate raporta zile");
        _;
    }

    constructor(address _agent, uint256 _maxPerTransaction, uint256 _weeklyLimit) {
        owner = msg.sender;
        agent = _agent;
        maxPerTransaction = _maxPerTransaction;
        weeklyLimit = _weeklyLimit;
    }

 

    function onInstall(bytes calldata) external {
        smartAccount = msg.sender;
    }

    function onUninstall(bytes calldata) external {
        smartAccount = address(0);
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    function isInitialized(address account) external view returns (bool) {
        return smartAccount == account;
    }



    function validateTransaction(
        address, /* from */
        address, /* to */
        uint256 value
    ) external view returns (bool) {
     
        if (value > maxPerTransaction) {
            return false;
        }

        uint256 weekTotal = getWeeklyTotal(lastReportedDay);
        if (weekTotal + value > weeklyLimit) {
            return false;
        }

        return true;
    }


    function reportDay(uint256 dayIndex, uint256 amount) external onlyAgent {
        require(dayIndex >= lastReportedDay, "Nu poti raporta o zi din trecut");

        dailySpend[dayIndex] += amount;
        lastReportedDay = dayIndex;

        uint256 weekTotal = getWeeklyTotal(dayIndex);
        emit DayReported(dayIndex, amount, weekTotal);
    }



    function getWeeklyTotal(uint256 currentDay) public view returns (uint256) {
        uint256 total = 0;
     
        uint256 startDay = currentDay >= 6 ? currentDay - 6 : 0;
        for (uint256 d = startDay; d <= currentDay; d++) {
            total += dailySpend[d];
        }
        return total;
    }



    function setLimits(uint256 _maxPerTransaction, uint256 _weeklyLimit) external onlyOwner {
        _requireChangeWithinBounds(maxPerTransaction, _maxPerTransaction);
        _requireChangeWithinBounds(weeklyLimit, _weeklyLimit);

        maxPerTransaction = _maxPerTransaction;
        weeklyLimit = _weeklyLimit;
        emit LimitsUpdated(_maxPerTransaction, _weeklyLimit);
    }

    function _requireChangeWithinBounds(uint256 oldValue, uint256 newValue) internal pure {
        uint256 diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
        uint256 maxDiff = (oldValue * MAX_CHANGE_PERCENT) / 100;
        require(diff <= maxDiff, "Schimbare prea mare: peste procentul maxim permis per apel");
    }

    function setAgent(address _agent) external onlyOwner {
        agent = _agent;
        emit AgentUpdated(_agent);
    }
}
