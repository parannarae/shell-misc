date_iso_8601="2020-10-27T14:11:07.342000+09:00"
format='%y%m%d%H%M'
# remove millisecond and `:` in offset (both are not supported in BSD date function)
intermediate_date=$(echo ${date_iso_8601} | sed -E 's/(\.[0-9]{6})//g' | sed -E 's/:([0-9]{2})$/\1/g')
printf "original: %s, modified: %s" "${date_iso_8601}" "${intermediate_date}"
date -jf '%Y-%m-%dT%H:%M:%S%z' "${intermediate_date}" +"${format}"

