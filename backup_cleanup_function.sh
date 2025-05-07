#=====================================================
# Cleanup function with improved error handling      #
#=====================================================
cleanup() {

  prefix="$1"
  exp_days=$(expiration_days "$prefix")
  echo "Cleaning up folder with prefix $prefix and expiration hours/days $exp_days"

  DBLIST=$(psql -p 5432 -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -d postgres -q -t -c \
        "select datname from pg_database where not datistemplate" | grep '\S' | awk '{print $1}')

  for DBNAME in $DBLIST; do
    if [[ "$DBNAME" != "postgres" ]]; then
      dir_to_clean="$BACKUP_DIR/$DBNAME"

      # Check if the directory exists
      if [ ! -d "$dir_to_clean" ]; then
          echo "Directory $dir_to_clean does not exist."
          exit 1
      fi

      # Find and delete files older than expiration days in the specified directory
      find "$dir_to_clean" -type f -mtime +"$exp_days" -name "*$prefix*" -exec rm {} \;

      # Check if any files were deleted
      if [ $? -eq 0 ]; then
          echo "$prefix backups older than $exp_days days were deleted from $dir_to_clean."
          if [ "$LOG_LEVEL" = "all" ]; then
            MESSAGE="$prefix backups older than $exp_days days were deleted from $dir_to_clean."
            #curl -X POST -H 'Content-type: application/json' --data '{"text":"$MESSAGE"}' $WEBHOOK
            wget --header='Content-Type:application/json' \
            --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":raised_hands:\"}" \
            $WEBHOOK  &>/dev/null || true
          fi
      else
          echo "No files older than $exp_days days found to delete in $dir_to_clean."
      fi

      # Find and delete empty directories in the specified directory
      find "$dir_to_clean" -type d -empty -exec rm -r {} \;

      # Check if empty directories were deleted
      if [ $? -eq 0 ]; then
          echo "Empty directories have been deleted from $dir_to_clean."
      else
          echo "No empty directories have been deleted from $dir_to_clean."
      fi
      exit 0

    fi
  done

}