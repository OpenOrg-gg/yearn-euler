import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)

@pytest.fixture
def reward():
    token_address = "0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)

@pytest.fixture
def eToken():
    token_address = "0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)

@pytest.fixture
def debtToken():
    token_address = "0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield token_address

@pytest.fixture
def name():
    token_address = "Strat"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield token_address

@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x55fe002aeff02f77364de339a1292923a15844b8", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount

@pytest.fixture
def reserveAccount(accounts):
    reserveAccount = accounts.at("0x27182842E098f60e3D576794A5bFFb0777E025d3", force=True)
    yield reserveAccount

@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, eToken, debtToken, name, reward):
    strategy = strategist.deploy(Strategy, vault, eToken, debtToken, name)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy

@pytest.fixture
def token_whale(accounts):
    yield accounts.at("0x7abe0ce388281d2acf297cb089caef3819b13448", force=True)


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
