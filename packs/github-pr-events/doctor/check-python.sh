#!/bin/sh
python3 -c "import sys; assert sys.version_info >= (3, 11), f'need 3.11+, got {sys.version}'" 2>/dev/null
