// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

interface IModule {
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
} 

interface IValidator is IModule {
    function validateTransaction(
        address from,
        address to,
        uint256 value
    ) external returns (bool);
}


contract SmartAccount {

    address public owner;

    mapping(address => bool) public installedModules;
    address[] public moduleList;

    event ModuleInstalled(address indexed module);
    event ModuleUninstalled(address indexed module);
    event TransactionExecuted(address indexed to, uint256 value);
    event TransactionRejected(address indexed to, uint256 value, string reason);

    modifier onlyOwner() {
        require(msg.sender == owner, "SmartAccount: doar owner-ul poate face asta");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}


    function installModule(address module) external onlyOwner {
        require(!installedModules[module], "Modulul e deja instalat");
        installedModules[module] = true;
        moduleList.push(module);
        IModule(module).onInstall("");
        emit ModuleInstalled(module);
    }

    function uninstallModule(address module) external onlyOwner {
        require(installedModules[module], "Modulul nu e instalat");
        installedModules[module] = false;
        IModule(module).onUninstall("");
        emit ModuleUninstalled(module);
    }

    function getInstalledModules() external view returns (address[] memory) {
        return moduleList;
    }


    function execute(address to, uint256 value) external onlyOwner {
        require(address(this).balance >= value, "SmartAccount: fonduri insuficiente");

        for (uint256 i = 0; i < moduleList.length; i++) {
            address module = moduleList[i];
            if (installedModules[module]) {
                bool allowed = IValidator(module).validateTransaction(msg.sender, to, value);
                if (!allowed) {
                    emit TransactionRejected(to, value, "Refuzata de modul");
                    revert("SmartAccount: tranzactia a fost refuzata de un modul de politici");
                }
            }
        }

        (bool success, ) = to.call{value: value}("");
        require(success, "SmartAccount: transferul a esuat");
        emit TransactionExecuted(to, value);
    }
}
