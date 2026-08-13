from example import add, percent


def test_add() -> None:
    assert add(2, 3) == 5


def test_add_is_commutative() -> None:
    assert add(2, 3) == add(3, 2)


def test_percent() -> None:
    assert percent(1, 1) == 100
