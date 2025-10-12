#!/bin/bash

# package_spoons.sh
# Script to package Hammerspoon Spoons for release
# Usage: ./package_spoons.sh [version]

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SPOONS_DIR="Spoons"
BUILD_DIR="build"
VERSION="${1:-latest}"

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to clean build directory
clean_build() {
    if [ -d "$BUILD_DIR" ]; then
        print_info "Cleaning existing build directory..."
        rm -rf "$BUILD_DIR"
    fi
    mkdir -p "$BUILD_DIR"
}

# Function to package a single Spoon
package_spoon() {
    local spoon_name="$1"
    local spoon_path="${SPOONS_DIR}/${spoon_name}"

    if [ ! -d "$spoon_path" ]; then
        print_error "Spoon directory not found: $spoon_path"
        return 1
    fi

    print_info "Packaging ${spoon_name}..."

    # Create a clean copy in build directory
    local build_spoon_path="${BUILD_DIR}/${spoon_name}"
    cp -r "$spoon_path" "$build_spoon_path"

    # Remove any .DS_Store files or other unwanted files
    find "$build_spoon_path" -name ".DS_Store" -delete 2>/dev/null || true
    find "$build_spoon_path" -name "*.swp" -delete 2>/dev/null || true
    find "$build_spoon_path" -name "*~" -delete 2>/dev/null || true

    # Create the zip file
    local zip_name="${spoon_name}.zip"
    (cd "$BUILD_DIR" && zip -r "$zip_name" "$spoon_name" -q)

    # Remove the temporary directory
    rm -rf "$build_spoon_path"

    print_success "Created ${BUILD_DIR}/${zip_name}"
}

# Function to create release info
create_release_info() {
    local release_file="${BUILD_DIR}/RELEASE.md"

    print_info "Creating release information..."

    cat > "$release_file" << EOF
# Hammerspoon Spoons Release

Version: ${VERSION}
Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

## Included Spoons

### WindowQuickJump.spoon
Jump to any window instantly with visual badges (1-9, A-Z).

### WindowCycle.spoon
Cycle through windows and spaces seamlessly with keyboard shortcuts.

### WindowManager.spoon
Advanced window manager with tiling layouts and fullscreen space management.

## Installation

1. Download the desired .spoon.zip file
2. Double-click to install (or unzip to ~/.hammerspoon/Spoons/)
3. Configure in your init.lua (see README for examples)

## Checksums

\`\`\`
EOF

    # Add checksums for all zip files
    if command -v shasum >/dev/null 2>&1; then
        (cd "$BUILD_DIR" && shasum -a 256 *.zip >> "RELEASE.md")
        echo '```' >> "$release_file"
    else
        echo '(checksums not available - shasum command not found)' >> "$release_file"
        echo '```' >> "$release_file"
    fi

    print_success "Created release information"
}

# Main script
main() {
    print_info "Starting Spoons packaging process..."
    print_info "Version: ${VERSION}"

    # Check if we're in the right directory
    if [ ! -d "$SPOONS_DIR" ]; then
        print_error "Spoons directory not found. Please run this script from the repository root."
        exit 1
    fi

    # Clean and create build directory
    clean_build

    # Find and package all Spoons
    local spoon_count=0
    for spoon_dir in "$SPOONS_DIR"/*.spoon; do
        if [ -d "$spoon_dir" ]; then
            spoon_name=$(basename "$spoon_dir")
            if package_spoon "$spoon_name"; then
                ((spoon_count++))
            fi
        fi
    done

    if [ $spoon_count -eq 0 ]; then
        print_error "No Spoons found to package"
        exit 1
    fi

    # Create release information
    create_release_info

    # Summary
    echo ""
    print_success "Packaging complete!"
    print_info "Packaged ${spoon_count} Spoon(s)"
    print_info "Output directory: ${BUILD_DIR}/"
    echo ""
    echo "Files created:"
    ls -lh "${BUILD_DIR}/"*.zip 2>/dev/null | awk '{print "  • " $9 " (" $5 ")"}'
    echo ""

    # Instructions for release
    if [ "$VERSION" != "latest" ]; then
        echo "To create a GitHub release:"
        echo "  1. git tag -a v${VERSION} -m 'Release v${VERSION}'"
        echo "  2. git push origin v${VERSION}"
        echo "  3. Upload the files from ${BUILD_DIR}/ to the GitHub release"
    else
        echo "To create a GitHub release:"
        echo "  1. Choose a version number (e.g., 1.0.0)"
        echo "  2. Run: ./package_spoons.sh 1.0.0"
        echo "  3. Follow the git tag instructions"
    fi
}

# Run main function
main "$@"
