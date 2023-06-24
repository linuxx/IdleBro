#!/bin/bash

# Check if g++ is installed
if ! command -v g++ >/dev/null 2>&1; then
    echo "Error: g++ compiler is not installed."
    exit 1
fi

# Delete existing IdleBro binary if it exists
if [ -f "/opt/idlebro/IdleBro" ]; then
    rm -f "/opt/idlebro/IdleBro"
fi

# Compile IdleBro.cpp and generate IdleBro binary
g++ IdleBro.cpp -o IdleBro

# Create /opt/idlebro directory
mkdir -p /opt/idlebro

# Copy IdleBro binary to /opt/idlebro (overwrite if exists)
cp -f IdleBro /opt/idlebro/IdleBro

# Copy idlebro.conf to /etc/idlebro (overwrite if exists)
mkdir -p /etc/idlebro
cp -f idlebro.conf /etc/idlebro/idlebro.conf

# Copy startscript.init.d to /etc/init.d/idlebro (overwrite if exists)
cp -f startscript.init.d /etc/init.d/idlebro

# Set permissions for IdleBro binary
chmod +x /opt/idlebro/IdleBro

# Set permissions for startscript.init.d
chmod +x /etc/init.d/idlebro

# Add IdleBro to init system
update-rc.d idlebro defaults

echo "IdleBro installation completed successfully."

