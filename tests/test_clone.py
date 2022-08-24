import pytest

from brownie import chain, Wei, reverts, Contract


def test_double_init_should_revert(
    strategy,
    vault,
    token,
    strategist,
    gov,
    keeper,
    rewards,
    eToken,
    debtToken,
    name,
):
    clone_tx = strategy.clone(
        vault,
        strategist,
        rewards,
        keeper,
        eToken,
        debtToken,
        "ClonedStrategy",
        {"from": strategist},
    )

    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.events["Cloned"]["clone"], strategy.abi
    )

    with reverts():
        strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            eToken,
            debtToken,
            "RevertedStrat",
            {"from": gov},
        )

    with reverts():
        cloned_strategy.initialize(
            vault,
            strategist,
            rewards,
            keeper,
            eToken,
            debtToken,
            "ClonedRevertedStrat",
            {"from": gov},
        )


def test_clone(
    strategy,
    vault,
    strategist,
    token,
    gov,
    keeper,
    rewards,
    token_whale,
    amount,
    eToken,
    debtToken,
    name,
):
    clone_tx = strategy.clone(
        vault,
        strategist,
        rewards,
        keeper,
        eToken,
        debtToken,
        "ClonedStrategy",
        {"from": strategist},
    )

    cloned_strategy = Contract.from_abi(
        "Strategy", clone_tx.events["Cloned"]["clone"], strategy.abi
    )

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    vault.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 0, {"from": gov})

    token.approve(vault, 2 ** 256 - 1, {"from": token_whale})
    vault.deposit(amount, {"from": token_whale})

    chain.sleep(1)
    cloned_strategy.harvest({"from": gov})

    # Sleep for 2 days
    chain.sleep(60 * 60 * 24 * 2)
    chain.mine(1)
    cloned_strategy.harvest({"from": gov})

    assert (
        vault.strategies(cloned_strategy).dict()["totalLoss"] < 10
    )  # might be a loss from rounding
