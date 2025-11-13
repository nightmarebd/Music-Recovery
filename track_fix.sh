#!/bin/bash

# --- Configuration ---
# Set the name of the main Python script
PYTHON_SCRIPT="track_fix.py"
# Set the name of the Python Virtual Environment directory
VENV_DIR=".venv"
# Check if Python 3.13 is available, if not, use the standard python3
if command -v python3.13 &> /dev/null
then
    PYTHON_EXEC="python3.13"
else
    PYTHON_EXEC="python3"
fi

# --- Functions ---

# Function to check for required commands
check_command() {
    if ! command -v "$1" &> /dev/null
    then
        echo "Error: Required command '$1' not found. Please install it."
        exit 1
    fi
}

# Function to set up the virtual environment
setup_venv() {
    echo "--- Setting up Python Virtual Environment ---"
    # Check if a virtual environment already exists
    if [ ! -d "$VENV_DIR" ]; then
        echo "Creating virtual environment in $VENV_DIR..."
        "$PYTHON_EXEC" -m venv "$VENV_DIR"
        if [ $? -ne 0 ]; then
            echo "Error creating virtual environment. Ensure $PYTHON_EXEC and 'venv' module are installed."
            exit 1
        fi
    fi
    
    # Activate the virtual environment (syntax differs slightly for sub-shells)
    # We use the full path to activate for simplicity within the script
    source "$VENV_DIR/bin/activate"

    # Install dependencies
    echo "Installing required Python dependencies from requirements.txt..."
    pip install --upgrade pip
    pip install -r requirements.txt
    
    if [ $? -ne 0 ]; then
        echo "Error installing dependencies. Check requirements.txt or internet connection."
        deactivate # Deactivate on failure
        exit 1
    fi
}

# --- Main Execution ---

# 1. Clean up old errors/documentation from the script start
echo "# NightmareBD Track Fix Utility"

# 2. Check for basic requirements
check_command "$PYTHON_EXEC"
check_command "pip"

# 3. Set up environment and install dependencies
setup_venv

# 4. Run the main Python script
echo "--- Starting Track Fix Utility ---"
# Pass all command-line arguments (like 'dry-run' or file paths) to the Python script
"$PYTHON_EXEC" "$PYTHON_SCRIPT" "$@"

# 5. Deactivate the virtual environment
deactivate

echo "--- Script finished ---"
