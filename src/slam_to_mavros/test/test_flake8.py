# Copyright 2026 speaker
# Licensed under the Apache License, Version 2.0

from ament_flake8.main import main
import pytest


@pytest.mark.linter
@pytest.mark.flake8
def test_flake8():
    return main(argv=['.', 'test'])