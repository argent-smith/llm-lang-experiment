"""Errors the client reports to the user."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterator


class ClientError(Exception):
    """A command failed; the message is meant for the user."""


@dataclass(frozen=True)
class Failure:
    """A file, or a whole directory, that a command could not process."""

    key: str
    message: str  # names the file and says what went wrong
    directory: bool = False  # a directory that could not be read: nothing under it was looked at


class Failures:
    """The files a command failed on, while it goes on with the rest.

    Each failure is passed to ``error`` as it happens; the command line
    reports them all again at the end.
    """

    def __init__(self, error: Callable[[str], None]) -> None:
        self._error = error
        self._items: list[Failure] = []
        self._dirs: set[str] = set()
        self._keys: set[str] = set()

    def add(self, key: str, message: str, directory: bool = False) -> None:
        self._items.append(Failure(key, message, directory))
        (self._dirs if directory else self._keys).add(key)
        self._error(message)

    def covers(self, key: str) -> bool:
        """Whether a failure has been recorded for ``key`` or a directory it is in."""
        if key in self._keys:
            return True
        parts = key.split("/")
        return any("/".join(parts[:depth]) in self._dirs for depth in range(1, len(parts)))

    def __iter__(self) -> Iterator[Failure]:
        return iter(self._items)

    def __len__(self) -> int:
        return len(self._items)
