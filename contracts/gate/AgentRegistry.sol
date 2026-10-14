// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {GateBase} from "./GateBase.sol";

/// @title AgentRegistry
/// @notice Which agent may submit orders for which account, and until when
///         (policy A8, expiry and revocation).
///
/// This entry is the whole of an agent's authority. The agent holds no key on
/// the prosumer account and signs nothing for it; it is an ordinary caller of
/// `submit` that the gate recognises. Revoking it is one owner call, effective
/// in the same block.
abstract contract AgentRegistry is GateBase {
    mapping(address account => mapping(uint64 generation => mapping(address agent => uint48))) private _validUntil;

    event AgentRegistered(address indexed account, address indexed agent, uint48 validUntil);
    event AgentRevoked(address indexed account, address indexed agent);

    error AgentRegistry_InvalidAgent(address agent);
    error AgentRegistry_AlreadyExpired(uint48 validUntil);

    /// @notice Register an agent for the calling account, or move the end of
    ///         its validity. Owner path.
    /// @param validUntil Last second at which the agent may submit.
    function registerAgent(address agent, uint48 validUntil) external onlyAccount nonReentrant {
        // The account is never its own agent, and neither is the gate: both
        // would let a call arrive at `submit` carrying owner-path authority.
        if (agent == address(0) || agent == msg.sender || agent == address(this)) {
            revert AgentRegistry_InvalidAgent(agent);
        }
        if (validUntil < block.timestamp) revert AgentRegistry_AlreadyExpired(validUntil);

        _validUntil[msg.sender][generationOf(msg.sender)][agent] = validUntil;
        emit AgentRegistered(msg.sender, agent, validUntil);
    }

    /// @notice Withdraw an agent's authority at once. Owner path.
    function revokeAgent(address agent) external onlyAccount nonReentrant {
        delete _validUntil[msg.sender][generationOf(msg.sender)][agent];
        emit AgentRevoked(msg.sender, agent);
    }

    /// @notice Zero when the agent is not registered for the account.
    function agentValidUntil(address account, address agent) public view returns (uint48) {
        return _validUntil[account][generationOf(account)][agent];
    }

    /// @notice Whether `agent` may submit for `account` right now.
    function isAgentActive(address account, address agent) public view returns (bool) {
        if (!isInstalled(account)) return false;

        uint48 validUntil = agentValidUntil(account, agent);
        return validUntil != 0 && block.timestamp <= validUntil;
    }
}
