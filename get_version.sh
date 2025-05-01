#!/bin/bash

# Enhanced version detection script for Retool environments
# Usage: get_version.sh [environment] [policy] [specific_version]
# Example: get_version.sh prod stable
#          get_version.sh staging latest
#          get_version.sh dev specific v2.123.0

ENVIRONMENT=$1
POLICY=$2
SPECIFIC_VERSION=$3

# Function to get stable version (filtering out canary and development builds)
get_stable_version() {
    curl -s https://hub.docker.com/v2/repositories/tryretool/backend/tags?page_size=100 | \
    grep -o '"name":"[^"]*"' | grep -v latest | grep -v canary | grep -v beta | \
    grep -v alpha | grep -v rc | head -1 | cut -d'"' -f4
}

# Function to get latest version (including development builds)
get_latest_version() {
    curl -s https://hub.docker.com/v2/repositories/tryretool/backend/tags?page_size=10 | \
    grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Function to validate a specific version exists
validate_specific_version() {
    VERSION=$1
    CHECK=$(curl -s https://hub.docker.com/v2/repositories/tryretool/backend/tags?page_size=100 | \
    grep -o "\"name\":\"$VERSION\"")
    
    if [ -z "$CHECK" ]; then
        echo "ERROR: Version $VERSION not found in Docker Hub"
        exit 1
    fi
    
    echo $VERSION
}

# Get version based on policy
case $POLICY in
    stable)
        VERSION=$(get_stable_version)
        ;;
    latest)
        VERSION="latest"  # Consistently use "latest" for the latest policy
        ;;
    specific)
        if [ -z "$SPECIFIC_VERSION" ]; then
            echo "ERROR: Specific version policy requires a version argument" >&2
            exit 1
        fi
        VERSION=$SPECIFIC_VERSION
        ;;
    *)
        echo "ERROR: Unknown policy '$POLICY'. Use 'stable', 'latest', or 'specific'" >&2
        exit 1
        ;;
esac

# Log information to stderr so it doesn't affect the returned value
echo "Selected version for $ENVIRONMENT environment: $VERSION" >&2

# Return only the clean version string without any extra text
echo "$VERSION"
