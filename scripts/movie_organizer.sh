#!/bin/bash

# Movie file organization script
# Searches radarr and radarr_unpackerred directories for media files
# and moves them to /mnt/media/movies/MOVIE_NAME/

# Log file location
LOG_FILE="$HOME/movie_organizer.log"

# Source directories to search
SOURCE_DIRS=("/media/qbittorrent/complete/radarr" "/media/qbittorrent/complete/radarr_unpackerred")

# Destination directory
DEST_DIR="/mnt/media/movies"

# Video file extensions to search for
VIDEO_EXTENSIONS=("mkv" "mp4" "avi" "m4v" "mov" "wmv")

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$1"
}

# Create log file if it doesn't exist
touch "$LOG_FILE"
log_message "Starting movie organization script"

# Check if destination directory exists
if [ ! -d "$DEST_DIR" ]; then
    log_message "Error: Destination directory $DEST_DIR does not exist"
    exit 1
fi

# Build the find command with all extensions
find_cmd="find"
extension_pattern=""

for ext in "${VIDEO_EXTENSIONS[@]}"; do
    if [ -z "$extension_pattern" ]; then
        extension_pattern="-name \"*.$ext\""
    else
        extension_pattern="$extension_pattern -o -name \"*.$ext\""
    fi
done

# Process each source directory
for src_dir in "${SOURCE_DIRS[@]}"; do
    if [ ! -d "$src_dir" ]; then
        log_message "Warning: Source directory $src_dir does not exist, skipping"
        continue
    fi
    
    log_message "Searching for video files in $src_dir"
    
    # Find all video files in the source directory
    # Using a combination of find and while read to handle filenames with spaces
    eval "$find_cmd \"$src_dir\" -type f \( $extension_pattern \) -print0" | while IFS= read -r -d $'\0' file; do
        # Get the filename and extension
        filename=$(basename "$file")
        extension="${filename##*.}"
        filename_no_ext="${filename%.*}"
        
        # Clean up the filename to create a proper directory name
        # Remove common patterns found in movie filenames
        movie_name=$(echo "$filename_no_ext" | sed -E 's/\.(1080p|720p|2160p|UHD|HDR|BluRay|WEB-DL|WEBRip|REMUX|IMAX|BDRip|DVDRip|PROPER|REPACK).*//I' | sed -E 's/\[[^]]*\]//g' | sed -E 's/\([^)]*\)//g' | sed 's/\._/ /g' | sed 's/\./ /g' | sed 's/_/ /g' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //' | sed 's/ $//')
        
        # Create destination directory
        movie_dir="$DEST_DIR/$movie_name"
        
        if [ ! -d "$movie_dir" ]; then
            log_message "Creating directory: $movie_dir"
            mkdir -p "$movie_dir"
        fi
        
        # Copy the file
        log_message "Copying: $file to $movie_dir/$filename"
        cp "$file" "$movie_dir/$filename"
        
        # If the copy was successful, check for subtitle files
        if [ $? -eq 0 ]; then
            # Look for subtitle files with the same base name
            subtitle_base="${file%.*}"
            find "$(dirname "$file")" -type f -name "${subtitle_base}*.srt" -o -name "${subtitle_base}*.sub" -o -name "${subtitle_base}*.idx" -o -name "${subtitle_base}*.ass" | while read -r subtitle; do
                subtitle_filename=$(basename "$subtitle")
                log_message "Copying subtitle: $subtitle to $movie_dir/$subtitle_filename"
                cp "$subtitle" "$movie_dir/$subtitle_filename"
            done
        fi
    done
done

# Set permissions and ownership on the destination directory
log_message "Setting permissions and ownership on $DEST_DIR"
sudo chmod 755 -Rfv "$DEST_DIR"
sudo chown jordan:jordan -Rfv "$DEST_DIR"

log_message "Movie copying completed"
exit 0
