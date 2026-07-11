# Copyright 2026 speaker
# Licensed under the Apache License, Version 2.0

from ament_pep257.main import main
import pytest


@pytest.mark.linter
@pytest.mark.pep257
def test_pep257():
    return main(argv=['.', 'test'])