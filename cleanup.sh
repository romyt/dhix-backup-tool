#!/bin/sh

# Specify the directory to clean
directory_to_clean="data/backups/dhis/"

# Check if the directory exists
if [ ! -d "$directory_to_clean" ]; then
    echo "Directory $directory_to_clean does not exist."
    exit 1
fi

# Find and delete files older than 5 days in the specified directory
find "$directory_to_clean" -type f -mtime +20 -name "*_daily_*" -exec rm {} \;

# Check if any files were deleted
if [ $? -eq 0 ]; then
    echo "Files older than 5 days have been deleted from $directory_to_clean."
else
    echo "No files older than 5 days found to delete in $directory_to_clean."
fi

# Find and delete empty directories in the specified directory
find "$directory_to_clean" -type d -empty -exec rm -r {} \;

# Check if empty directories were deleted
  if [ $? -eq 0 ]; then
     echo "Empty directories have been deleted from $directory_to_clean."
  else
     echo "No empty directories have been deleted from $directory_to_clean."
  fi
exit 0