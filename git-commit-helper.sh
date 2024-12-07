#!/usr/bin/env bash
# ^ Using /usr/bin/env for better portability across shells

# Configuration
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git-commit-helper"
CONFIG_FILE="$CONFIG_DIR/config.json"
CACHE_DIR="$CONFIG_DIR/cache"
CACHE_DURATION=3600  # Cache duration in seconds (1 hour)

# Create necessary directories
mkdir -p "$CONFIG_DIR" "$CACHE_DIR"

# Create default config if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
{
    "api_key": "",
    "model": "claude-3-sonnet-20240229",
    "commit_types": [
        "feat", "fix", "docs", "style", "refactor",
        "perf", "test", "chore", "ci", "build"
    ],
    "max_tokens": 300
}
EOF
fi

# Function to show help
show_help() {
    cat << 'EOF'
Usage: git-commit-helper [OPTIONS]
Options:
  -t, --type TYPE     Specify commit type (feat, fix, etc.)
  -s, --scope SCOPE   Specify commit scope
  -h, --help         Show this help message
  --configure        Configure API key
  --interactive      Run in interactive mode (default)
EOF
}

# Function to load config
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Configuration file not found" >&2
        exit 1
    fi
    # Using Python to parse JSON as it's more reliable than jq for complex operations
    python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    config = json.load(f)
print(config.get('api_key', ''))
"
}

# Function to configure API key
configure_api_key() {
    echo -n "Enter your Anthropic API key: "
    read -r api_key
    # Using Python to update JSON config
    python3 -c "
import json
config = {}
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)
config['api_key'] = '$api_key'
with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=4)
"
    echo "API key configured successfully!"
}

# Function to get git diff
get_git_diff() {
    git diff --cached --diff-algorithm=minimal
}

# Function to get recent commits
get_recent_commits() {
    git log -3 --pretty=format:"%B"
}

# Function to generate commit message using Claude
generate_commit_message() {
    local diff_context="$1"
    local commit_type="$2"
    local scope="$3"
    local api_key
    api_key=$(load_config)

    if [ -z "$api_key" ]; then
        echo "Error: API key not configured. Run 'git-commit-helper --configure'" >&2
        exit 1
    }

    # Create cache key based on diff content
    local cache_key
    cache_key=$(echo "$diff_context" | sha256sum | cut -d' ' -f1)
    local cache_file="$CACHE_DIR/$cache_key"

    # Check cache
    if [ -f "$cache_file" ]; then
        local cache_time
        local current_time
        cache_time=$(stat -c %Y "$cache_file")
        current_time=$(date +%s)
        if [ $((current_time - cache_time)) -lt "$CACHE_DURATION" ]; then
            cat "$cache_file"
            return
        fi
    fi

    # Prepare the prompt
    local prompt
    prompt=$(cat << EOF
Generate a git commit message following conventional commits format.
Type: $commit_type
${scope:+Scope: $scope}

Guidelines:
- First line: <type>${scope:+($scope)}: <description>
- Keep descriptions concise and direct
- Add bullet points for additional context if needed
- Leave second line blank if using bullet points
- Focus on what changed, not why
- Be specific but brief

Recent commits (for style reference):
$(get_recent_commits)

Changes to be committed:
$diff_context
EOF
)

    # Call Claude API
    local response
    response=$(curl -s https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: $api_key" \
        -H "anthropic-version: 2023-06-01" \
        --data-raw "{
            \"model\": \"claude-3-sonnet-20240229\",
            \"max_tokens\": 300,
            \"messages\": [{
                \"role\": \"user\",
                \"content\": $(echo "$prompt" | jq -R -s '.')
            }]
        }")

    # Extract and cache the commit message
    echo "$response" | jq -r '.content[0].text' | tee "$cache_file"
}

# Interactive mode function
interactive_mode() {
    # Load commit types from config
    local commit_types
    commit_types=$(jq -r '.commit_types[]' "$CONFIG_FILE")
    
    # Create array of commit types
    local -a types
    while IFS= read -r type; do
        types+=("$type")
    done <<< "$commit_types"
    
    # Display menu
    echo "Select commit type:"
    select type in "${types[@]}"; do
        if [ -n "$type" ]; then
            break
        fi
    done

    echo -n "Enter scope (optional, press enter to skip): "
    read -r scope
    
    local diff_context
    diff_context=$(get_git_diff)
    if [ -z "$diff_context" ]; then
        echo "Error: No staged changes found" >&2
        exit 1
    fi

    generate_commit_message "$diff_context" "$type" "$scope"
}

# Parse command line arguments
COMMIT_TYPE=""
SCOPE=""

while [ $# -gt 0 ]; do
    case $1 in
        -t|--type)
            COMMIT_TYPE="$2"
            shift 2
            ;;
        -s|--scope)
            SCOPE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --configure)
            configure_api_key
            exit 0
            ;;
        --interactive)
            interactive_mode
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Default to interactive mode if no type specified
if [ -z "$COMMIT_TYPE" ]; then
    interactive_mode
else
    diff_context=$(get_git_diff)
    if [ -z "$diff_context" ]; then
        echo "Error: No staged changes found" >&2
        exit 1
    fi
    generate_commit_message "$diff_context" "$COMMIT_TYPE" "$SCOPE"
fi
