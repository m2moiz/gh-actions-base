from example import add


def test_add() -> None:
    assert add(2, 3) == 5


def test_add_is_commutative() -> None:
    assert add(2, 3) == add(3, 2)
