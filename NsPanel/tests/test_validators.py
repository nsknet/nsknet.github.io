import pytest
from fastapi import HTTPException

from core import validators as v


@pytest.mark.parametrize("value", ["site", "my-site.com", "a_b.c-d", "x1"])
def test_require_name_accepts_safe_names(value):
    assert v.require_name(value) == value


@pytest.mark.parametrize(
    "value",
    ["", " ", "-leading", "has space", "semi;colon", "../escape", "back`tick", "dollar$"],
)
def test_require_name_rejects_unsafe_names(value):
    with pytest.raises(HTTPException) as exc:
        v.require_name(value)
    assert exc.value.status_code == 400


def test_require_name_rejects_traversal_that_matches_the_pattern():
    with pytest.raises(HTTPException):
        v.require_name("a..b")


def test_require_password_enforces_length_and_charset():
    assert v.require_password("Str0ng-Pass") == "Str0ng-Pass"
    for bad in ["", "short1", "has space!", "quote'inject", "back`tick", "dollar$sign"]:
        with pytest.raises(HTTPException):
            v.require_password(bad)


def test_require_choice():
    assert v.require_choice(" ext4 ", v.VALID_FSTYPES, "bad fs") == "ext4"
    with pytest.raises(HTTPException):
        v.require_choice("zfs", v.VALID_FSTYPES, "bad fs")
