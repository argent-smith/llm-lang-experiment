"""Errors the client reports to the user."""

from __future__ import annotations


class ClientError(Exception):
    """A command failed; the message is meant for the user."""
