#!/usr/bin/env bash
# Variable gathering and setting all needs to be auto-exported
set -a

COMMENT_CODE='///'
TAG_CODE='@@'
PREVIEW_STOP_CODE='{preview-stop}'
TOC_CODE='{toc}'
TITLE_SEPARATOR_CHAR='-'
POST_EXTENSION='bm'
POST_DIR='posts'
BUILD_DIR="build"
INCLUDE_DIR="include"
METADATA_DIR="meta"
BUILT_POST_DIR="${BUILD_DIR}/posts"
BUILT_SHORT_POST_DIR="${BUILD_DIR}/p"
BUILT_TAG_DIR="${BUILD_DIR}/tags"
BUILT_STATIC_DIR="${BUILD_DIR}/static"
M4="$(which m4)"
M4_FLAGS="--prefix-builtins"
MAKE="make"
MAKE_FLAGS="-j --output-sync --makefile internal/Makefile --quiet"
MKDIR="mkdir"
MKDIR_FLAGS="-p"
RM="rm"
RM_FLAGS="-fr"
VERSION="v3.0.0-develop"
TAG_ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
ID_ALPHABET="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
KNOWN_HASH_PROGRAMS="sha1sum sha1 sha256sum sha256 md5sum md5 cat"

# import more function definitions
source internal/options.sh

# get and validate all options
source internal/set-defaults.sh

if ! which "Markdown.pl" &> /dev/null
then
	MARKDOWN="./internal/Markdown.pl"
	if [ ! -x "${MARKDOWN}" ]
	then
		echo "Markdown.pl not found"
		exit 1
	fi
else
	MARKDOWN="$(which "Markdown.pl")"
fi

if ! which git &> /dev/null
then
	VERSION="${VERSION} ($(git rev-parse --short HEAD))"
fi

! which "${MAKE}" &> /dev/null && echo "error: make not found" && exit 1
! which "${M4}" &> /dev/null && echo "error: m4 not found" && exit 1

[ ! -x "${MARKDOWN}" ] && echo "error: Markdown.pl not found" && exit 1
[ ! -x "${M4}" ] && echo "error: m4 not found" && exit 1

# Parses the options in FILE into OP_FILE and returns the contents of OP_FILE.
# FILE must be an original post file. It cannot be temporary, even if it has
# full headers and content
function parse_options {
	FILE="$1"
	OPTIONS_IN="$(head -n 4 "${FILE}" | tail -n 1)"
	OP_FILE="$(mktemp)"
	for OP_V in $OPTIONS_IN
	do
		OP="$(echo "${OP_V}" | cut -d '=' -f 1)"
		V="$(echo "${OP_V}" | cut -d '=' -f 2)"
		[[ "${OP}" == "${V}" ]] && V="1"
		if [[ ${OP} =~ ^no_ ]]
		then
			OP="${OP#no_}"
			[[ "${V}" == "0" ]] && V="1" || V="0"
		fi
		op_set "${OP_FILE}" "${OP}" "${V}"
	done
	# Set post_file_name to FILE
	# post_file_name should never be set as an option, this is just to
	# make it easier to keep track of the original file name when we're
	# many temporary files deep
	op_set "${OP_FILE}" post_file_name "${FILE}"
	cat "${OP_FILE}"
	rm "${OP_FILE}"
}

# checks that the combination of options is valid for the given file.
# FILE is a full post file. It cannot be a temporary file, even if the
# temporary file has headers in addition to content.
# Also sets any options in the OPTIONS file that need setting
# For example, if heading_ids is __unset__ coming in but FILE has a {toc}
# then heading_ids will be set to true here
function validate_options {
	FILE="$1"
	OPTIONS="$2"
	if [[ "${FILE}" == "" ]] || [[ "${OPTIONS}" == "" ]]
	then
		echo "missing file or options file"
		return 1
	fi
	# If user wants a TOC, then heading_ids must be unset or set to on.
	# Set it to true if unset
	[[ "$(file_has_toc_code "${FILE}")" != "" ]] && \
		[[ "$(op_is_set "${OPTIONS}" heading_ids)" != "" ]] && \
		[[ "$(op_get "${OPTIONS}" heading_ids)" == "0" ]] && \
		echo "table of contents requested but heading_ids is off" && return 2
	[[ "$(file_has_toc_code "${FILE}")" != "" ]] && op_set "${OPTIONS}" heading_ids
	return 0
}

function strip_comments {
	FILE="$1"
	grep --invert-match "^${COMMENT_CODE}" "${FILE}"
}

function get_headers {
	FILE="$1"
	head -n 7 "${FILE}"
}

function get_date {
	FILE="$1"
	strip_comments "${FILE}" | \
		head -n 1
}

function get_mod_date {
	FILE="$1"
	strip_comments "${FILE}" | \
		head -n 2 | tail -n 1
}

function get_id {
	FILE="$1"
	strip_comments "${FILE}" | \
		head -n 3 | tail -n 1
}

function get_author {
	FILE="$1"
	strip_comments "${FILE}" | \
		head -n 6 | tail -n 1
}

function get_title {
	FILE="$1"
	strip_comments "${FILE}" | \
		head -n 7 | tail -n 1
}

function get_content {
	FILE="$1"
	strip_comments "${FILE}" | \
		tail -n +8
}

function get_toc {
	FILE="$1"
	[[ "$(file_has_toc_code "${FILE}")" == "" ]] && return
	TEMP_HTML="$(mktemp)"
	< "${FILE}" "${MARKDOWN}" > "${TEMP_HTML}"
	HEADINGS=( )
	LINE_NUMBERS=( )
	while read -r LINE
	do
		LINE_NUMBERS+=("$(echo ${LINE} | cut -d ':' -f 1)")
		HEADING="$(echo ${LINE} | cut -d ':' -f 2- |\
			sed 's|<h[[:digit:]]>\(.*\)</h[[:digit:]]>|\1|' |\
			title_to_heading_id)"
		WORKING_HEADING="#${HEADING}"
		if [[ -z ${!HEADINGS[@]} ]]
		then
			HEADINGS+=(${WORKING_HEADING})
		else
			I="0"
			while [[ " ${HEADINGS[@]} " =~ " ${WORKING_HEADING} " ]]
			do
				I=$((I+1))
				WORKING_HEADING="#${HEADING}-${I}"
			done
			HEADINGS+=(${WORKING_HEADING})
		fi
	done < <(grep --line-number "<h[[:digit:]]>" "${TEMP_HTML}")
	[[ -z ${!HEADINGS[@]} ]] && rm "${TEMP_HTML}" && return
	I="0"
	for HEADING in ${HEADINGS[@]}
	do
		LINE_NUM="${LINE_NUMBERS["${I}"]}"
		sed --in-place \
			-e "${LINE_NUM}s|<h\([[:digit:]]\)>|<h\1><a href=\'${HEADING}\'>|" \
			-e "${LINE_NUM}s|</h\([[:digit:]]\)>|</a></h\1>|" \
			"${TEMP_HTML}"
		I=$((I+1))
		#(( "${I}" > "2" )) && break
	done
	grep "<h[[:digit:]]>" "${TEMP_HTML}" |\
	sed 's|<h1>|- |' |\
	sed 's|<h2>|   - |' |\
	sed 's|<h3>|      - |' |\
	sed 's|<h4>|         - |' |\
	sed 's|<h5>|            - |' |\
	sed 's|<h6>|               - |' |\
	sed 's|<h7>|                  - |' |\
	sed 's|<h8>|                     - |' |\
	sed 's|<h9>|                        - |' |\
	sed 's|</h[[:digit:]]>||'
	rm "${TEMP_HTML}"
}

function title_to_heading_id {
	to_lower | strip_punctuation | strip_space | cut -d '-' -f -3
}

function title_to_post_url {
	to_lower | strip_punctuation | strip_space | cut -d '-' -f -3
}

function to_lower {
	tr '[:upper:]' '[:lower:]'
}

function strip_punctuation {
	tr -d '[:punct:]'
}

function strip_space {
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | \
		tr --squeeze-repeats '[:blank:]' "${TITLE_SEPARATOR_CHAR}"
}

function set_editor {
	if [[ "${ED}" == "" ]]
	then
		echo "\$ED not set."
		while read -p "Enter name of desired text editor: " ED
		do
			if ! which "${ED}" &> /dev/null
			then
				echo "That doesn't seem to be a valid editor."
			else
				break
			fi
		done
	fi
}

function ts_to_date {
	FRMT="$1"
	shift
	if [ ! -z "$1" ]
	then
		TS="$1"
		shift
	else
		read TS
	fi
	date --date="@${TS}" +"${FRMT}"
}

function get_tags {
	FILE="$1"
	cat ${FILE} | grep --extended-regexp --only-matching "${TAG_CODE}[${TAG_ALPHABET}]+" | \
		sed -e "s|${TAG_CODE}||g" | to_lower | \
		sort | uniq
}

function file_has_toc_code {
	FILE="$1"
	LINE_COUNT=$(strip_comments "${FILE}" | grep --ignore-case "${TOC_CODE}" | wc -l)
	[[ "${LINE_COUNT}" > 0 ]] && echo "foobar" || echo ""
}

function sort_by_date {
	# If sending file names in via stdin,
	# they must be \0 delimited
	ARRAY=( )
	if [[ $# -ge 1 ]]
	then
		FILE="$1"
		shift
		while [ 1 ]
		do
			DATE="$(get_date "${FILE}")"
			ARRAY["${DATE}"]="${FILE}"
			[[ $# -ge 1 ]] && FILE="$1" && shift || break
		done
	elif [ -p /dev/stdin ]
	then
		while read -d '' FILE
		do
			DATE="$(get_date "${FILE}")"
			ARRAY["${DATE}"]="${FILE}"
		done
	fi
	for I in "${!ARRAY[@]}"
	do
		echo "${ARRAY[$I]}"
	done
}

function get_hash_program {
	for PROGRAM in ${KNOWN_HASH_PROGRAMS} # No quotes on purpose
	do
		if which ${PROGRAM} &> /dev/null
		then
			echo "${PROGRAM}"
			break
		fi
	done
}

function hash_data {
	if [[ "${HASH_PROGRAM}" == "" ]]
	then
		HASH_PROGRAM=$(get_hash_program)
		if [[ "${HASH_PROGRAM}" == "" ]]
		then
			echo "Couldn't find any of: ${KNOWN_HASH_PROGRAMS}"
			echo "You need one, or to set HASH_PROGRAM to something which can"
			echo "hash data given on stdin for bm to work."
			exit 1
		fi
	fi
	${HASH_PROGRAM}
}

function generate_id {
	cat /dev/urandom | tr -cd "${ID_ALPHABET}" | head -c 8
}

function pretty_print_post_info {
	FILE="$1"
	echo "$(get_date "${FILE}" | ts_to_date "${DATE_FRMT}") (id=$(get_id "${FILE}")): $(get_title "${FILE}")"
}

# args: search terms
# returns 0 or more matched post file names
function search_posts {
	[[ ! -d "${POST_DIR}" ]] && return
	# valid TYPEs are 'both' and 'title'
	# where 'both' means title and post id
	[[ "$1" == "$@" ]] && TYPE="both" || TYPE="title"
	if [[ "${TYPE}" == "both" ]]
	then
		POSTS="$(search_posts_by_id "$@")"
		[[ "${POSTS}" != "" ]] && echo "${POSTS}" && return
		POSTS="$(search_posts_by_title "$@")"
		[[ "${POSTS}" != "" ]] && echo "${POSTS}" && return
	else
		POSTS="$(search_posts_by_title "$@")"
		[[ "${POSTS}" != "" ]] && echo "${POSTS}" && return
	fi
}

# args: search term
# returns 0 or 1 matched post file names
function search_posts_by_id {
	[[ "$1" != "$@" ]] && return
	[[ "$1" == "" ]] && return
	while read FILE
	do
		ID="$(get_id "${FILE}")"
		if [[ $ID =~ ^.*$1.*$ ]]
		then
			[[ "${POSTS}" != "" ]] && POSTS="${POSTS} ${FILE}" || POSTS="${FILE}"
		fi
	done < <(find "${POST_DIR}" -type f -name "*.${POST_EXTENSION}")
	COUNT="$(echo "${POSTS}" | wc -w)"
	[[ "${COUNT}" != "1" ]] && return
	echo "${POSTS}"
}

# args: search terms
# returns 0 or more matched post file names sorted by date
function search_posts_by_title {
	[[ "$1" == "" ]] && return
	while read FILE
	do
		TERMS="$(echo "$@" | to_lower | strip_punctuation | strip_space)"
		TITLE="$(get_title "${FILE}" | to_lower | strip_punctuation | strip_space)"
		if [[ $TITLE =~ ^.*${TERMS}.*$ ]]
		then
			[[ "${POSTS}" != "" ]] && POSTS="${POSTS} ${FILE}" || POSTS="${FILE}"
		fi
	done < <(find "${POST_DIR}" -type f -name "*.${POST_EXTENSION}")
	COUNT="$(echo "${POSTS}" | wc -w)"
	(( "${COUNT}" < "1" )) && return
	sort_by_date ${POSTS}
}

# give this function a file name containing all post ids
# it echos the ids of pinned posts in the correct order
function only_pinned_posts {
	ARRAY=( )
	for ID in $(cat $1)
	do
		OPTIONS="${METADATA_DIR}/${ID}/options"
		PINNED="$(op_get "${OPTIONS}" "pinned")"
		if [[ "${PINNED}" != "" ]] && (( "${PINNED}" > "0" ))
		then
			ARRAY["${PINNED}"]="${ID}"
		fi
	done
	for I in "${!ARRAY[@]}"
	do
		echo "${ARRAY[$I]}"
	done
}

# give this function a file name containing all post ids
# it calls only_pinned_posts and echos post ids that aren't pinned
function only_unpinned_posts {
	PINNED=( $(only_pinned_posts $1) )
	for ID in $(cat $1)
	do
		[[ ! " ${PINNED[@]} " =~ " ${ID} " ]] \
			&& echo "${ID}"
	done
}

function pre_markdown {
	ID="$1"
	METADATA="${METADATA_DIR}/${ID}"

	# 1: do table of contents

	TOC="$(cat "${METADATA}/toc")"
	# Somehow this works to allow sed to replace '{toc}' (single line) with
	# ${TOC_ESCAPED} (many lines)
	TOC_ESCAPED="$(printf '%s\n' "${TOC}" | sed 's|[\/&]|\\&|g;s|$|\\|')"
	TOC_ESCAPED="${TOC_ESCAPED%?}"
	sed "s|${TOC_CODE}|\\n${TOC_ESCAPED}\\n|"
}

function get_preview_content {
	CONTENT="$1"
	shift
	OPTIONS="$1"
	shift
	PREVIEW_STOP_LINE="$(grep --fixed-strings --line-number "${PREVIEW_STOP_CODE}" "${CONTENT}")"
	if [[ "${PREVIEW_STOP_LINE}" != "" ]]
	then
		PREVIEW_STOP_LINE="$(echo "${PREVIEW_STOP_LINE}" | head -n 1 | sed -E 's|^([0-9]+):.*|\1|')"
		head -n "${PREVIEW_STOP_LINE}" "${CONTENT}" | sed 's|{preview-stop}||'
	else
		local PREVIEW_MAX_WORDS="${PREVIEW_MAX_WORDS}"
		if [[ "$(op_is_set "${OPTIONS}" preview_max_words)" != "" ]]
		then
			PREVIEW_MAX_WORDS="$(op_get "${OPTIONS}" preview_max_words)"
		fi
		WORD_COUNT=0
		while IFS= read DATA
		do
			echo "${DATA}"
			WORD_COUNT=$((WORD_COUNT+$(echo "${DATA}" | wc -w)))
			if (( "${WORD_COUNT}" >= "${PREVIEW_MAX_WORDS}" ))
			then
				break
			fi
		done < "${CONTENT}"
	fi
}

# first arg is the post id
# remaining args are options
# valid options are: "for-preview"
function post_markdown {
	TMP1="$(mktemp)"
	TMP2="$(mktemp)"
	ID="$1" && shift
	OPTS=( "$@" )
	# 1: make tags into links

	sed -e "s|${TAG_CODE}\([${TAG_ALPHABET}]\+\)|<a href='${ROOT_URL}/tags/\L\1.html'>\E\1</a>|g" > "${TMP1}"

	# 2: remove various macros

	cat "${TMP1}" | \
		sed -e "s|${PREVIEW_STOP_CODE}||g" | \
		sed -e "s|${TOC_CODE}||g" > "${TMP2}" # TOC_CODE shouldn't be necessary as it will have been replaced already

	# 3: make heading ids if needed

	OPTIONS="${METADATA_DIR}/${ID}/options"
	if [[ "$(op_is_set "${OPTIONS}" heading_ids)" == "" ]]
	then
		cat "${TMP2}" > "${TMP1}"
	else
		HEADINGS=( )
		while read LINE
		do
			if [[ "$(echo "${LINE}" | grep "^<h[[:digit:]]>.*</h[[:digit:]]>" )" == "" ]]
			then
				echo "${LINE}"
				continue
			fi
			HEADING="$(echo ${LINE} | sed 's|^<h[[:digit:]]>\(.*\)</h[[:digit:]]>|\1|')"
			HEADING="$(echo "${HEADING}" | title_to_heading_id)"
			WORKING_HEADING="${HEADING}"
			while (( "${#HEADINGS[@]}" > "0" )) && [[ " ${HEADINGS[@]} " =~ " ${WORKING_HEADING} " ]]
			do
				I=$((I+1))
				WORKING_HEADING="${HEADING}-${I}"
			done
			HEADINGS+=(${WORKING_HEADING})
			echo "${LINE}" | sed \
				-e "s|^<h\([[:digit:]]\)>|<h\1 id=\'${WORKING_HEADING}'>|" \
				-e "s|</h\([[:digit:]]\)>|</h\1>|"
		done < "${TMP2}" > "${TMP1}"
	fi

	# DONE

	cat "${TMP1}" # output the final temp file. Odd num of steps means tmp1
	rm "${TMP1}" "${TMP2}"
}

function build_index {
	echo "m4_include(include/html.m4)"
	echo "START_HTML([[${ROOT_URL}]], [[${BLOG_TITLE}]])"
	echo "HOMEPAGE_HEADER_HTML([[${ROOT_URL}]], [[${BLOG_TITLE}]], [[${BLOG_SUBTITLE}]])"
	POSTS="$1"
	PINNED_POSTS="$(mktemp)"
	UNPINNED_POSTS="$(mktemp)"
	INCLUDED_POSTS=( )
	INCLUDED_POSTS_INDEX="0"
	only_pinned_posts "${POSTS}" > "${PINNED_POSTS}"
	only_unpinned_posts "${POSTS}" > "${UNPINNED_POSTS}"
	for POST in $(cat "${PINNED_POSTS}") $(tac "${UNPINNED_POSTS}" | head -n "${POSTS_ON_HOMEPAGE}")
	do
		HEADERS="${METADATA_DIR}/${POST}/headers"
		CONTENT="${METADATA_DIR}/${POST}/previewcontent"
		OPTIONS="${METADATA_DIR}/${POST}/options"
		TITLE="$(get_title "${HEADERS}")"
		POST_FILE="$(echo "${TITLE}" | title_to_post_url)${TITLE_SEPARATOR_CHAR}${POST}.html"
		if [[ "${PREFER_SHORT_POSTS}" == "yes" ]]
		then
			POST_LINK="${ROOT_URL}/p/${POST}.html"
		else
			POST_LINK="${ROOT_URL}/posts/${POST_FILE}"
		fi
		AUTHOR="$(get_author "${HEADERS}")"
		DATE="$(get_date "${HEADERS}")"
		MOD_DATE="$(get_mod_date "${HEADERS}")"
		(( "$((${MOD_DATE}-${DATE}))" > "${SIGNIFICANT_MOD_AFTER}" )) && MODIFIED="foobar" || MODIFIED=""
		DATE="$(ts_to_date "${DATE_FRMT}" "${DATE}")"
		MOD_DATE="$(ts_to_date "${LONG_DATE_FRMT}" "${MOD_DATE}")"
		PERMALINK="${ROOT_URL}/p/$(get_id "${HEADERS}").html"
		IS_PINNED="$(op_get "${OPTIONS}" pinned)"
		if [[ "$(cat "${METADATA_DIR}/${POST}/previewcontent" | hash_data)" != \
			"$(cat "${METADATA_DIR}/${POST}/content" | hash_data)" ]]
		then
			CONTENT_IS_TRIMMED="foobar"
		else
			CONTENT_IS_TRIMMED=""
		fi
		echo "START_HOMEPAGE_PREVIEW_HTML"
		echo "START_POST_HEADER_HTML([[<a href='${POST_LINK}'>${TITLE}</a>]], [[${DATE}]], [[${AUTHOR}]])"
		if [[ "${MODIFIED}" != "" ]]
		then
			echo "POST_HEADER_MOD_DATE_HTML([[${MOD_DATE}]])"
		fi
		if [[ "${MAKE_SHORT_POSTS}" == "yes" ]]
		then
			echo "POST_HEADER_PERMALINK_HTML([[${PERMALINK}]])"
		fi
		if [[ "${IS_PINNED}" != "" ]] && (( "${IS_PINNED}" > "0" ))
		then
			echo "POST_HEADER_PINNED_HTML"
		fi
		echo "END_POST_HEADER_HTML"
		< "${CONTENT}" \
		pre_markdown "$(get_id "${HEADERS}")" |\
		${MARKDOWN} |\
		post_markdown "$(get_id "${HEADERS}")"
		if [[ "${CONTENT_IS_TRIMMED}" != "" ]]
		then
			echo "<a href='${POST_LINK}'><em>Read the entire post</em></a>"
		fi
		echo "END_HOMEPAGE_PREVIEW_HTML"

		INCLUDED_POSTS["${INCLUDED_POSTS_INDEX}"]="${POST}"
		INCLUDED_POSTS_INDEX=$((INCLUDED_POSTS_INDEX+1))
	done
	echo "HOMEPAGE_FOOTER_HTML([[${ROOT_URL}]], [[${VERSION}]])"
	echo "END_HTML"
	rm "${PINNED_POSTS}" "${UNPINNED_POSTS}"
}

function build_content_header {
	METADATA="${METADATA_DIR}/$1"
	HEADERS="${METADATA}/headers"
	TITLE="$(get_title "${HEADERS}")"
	DATE="$(get_date "${HEADERS}")"
	MOD_DATE="$(get_mod_date "${HEADERS}")"
	(( "$((${MOD_DATE}-${DATE}))" > "${SIGNIFICANT_MOD_AFTER}" )) && \
		MODIFIED="foobar" || MODIFIED=""
	DATE="$(ts_to_date "${DATE_FRMT}" "${DATE}")"
	MOD_DATE="$(ts_to_date "${LONG_DATE_FRMT}" "${MOD_DATE}")"
	AUTHOR="$(get_author "${HEADERS}")"
	PERMALINK="${ROOT_URL}/p/$1.html"
	cat << EOF
m4_include(include/html.m4)
START_HTML([[${ROOT_URL}]], [[${TITLE} - ${BLOG_TITLE}]])
CONTENT_PAGE_HEADER_HTML([[${ROOT_URL}]], [[${BLOG_TITLE}]], [[${BLOG_SUBTITLE}]])
START_POST_HEADER_HTML([[${TITLE}]], [[${DATE}]], [[${AUTHOR}]])
EOF
	[[ "${MODIFIED}" != "" ]] && cat << EOF
POST_HEADER_MOD_DATE_HTML([[${MOD_DATE}]])
EOF
	[[ "${MAKE_SHORT_POSTS}" == "yes" ]] && cat << EOF
POST_HEADER_PERMALINK_HTML([[${PERMALINK}]])
EOF
	cat << EOF
END_POST_HEADER_HTML
EOF
}

function build_content_footer {
	cat << EOF
m4_include(include/html.m4)
CONTENT_PAGE_FOOTER_HTML([[${ROOT_URL}]], [[${VERSION}]])
END_HTML
EOF
}

function build_tagindex {
	ALL_TAGS=( $(cat "${METADATA_DIR}/tags") )
	# first get all post headers
	TMP=( $(find "${METADATA_DIR}/" -mindepth 2 -type f -name headers) )
	# then sort the headers by date
	TMP=( $(sort_by_date ${TMP[@]} | tac) )
	# then change from headers to tags
	ALL_POSTS=( )
	for P in ${TMP[@]}; do ALL_POSTS[${#ALL_POSTS[@]}]="$(dirname ${P})/tags"; done
	# finally, build page
	echo "m4_include(include/html.m4)"
	echo "START_HTML([[${ROOT_URL}]], [[Tags - ${BLOG_TITLE}]])"
	echo "CONTENT_PAGE_HEADER_HTML([[${ROOT_URL}]], [[${BLOG_TITLE}]], [[${BLOG_SUBTITLE}]])"
	for T in ${ALL_TAGS[@]}
	do
		CURRENT_EPOCH=
		TMP_TAG_FILE="$(mktemp)"
		TAG_FILE="${BUILT_TAG_DIR}/${T}.html"
		echo "m4_include(include/html.m4)" >> "${TMP_TAG_FILE}"
		echo "START_HTML([[${ROOT_URL}]], [[${T} - ${BLOG_TITLE}]])" >> "${TMP_TAG_FILE}"
		echo "CONTENT_PAGE_HEADER_HTML([[${ROOT_URL}]], [[${BLOG_TITLE}]], [[${BLOG_SUBTITLE}]])" >> "${TMP_TAG_FILE}"
		echo "<h1>${T}</h1>" | tee -a "${TMP_TAG_FILE}"
		echo "<ul>" | tee -a "${TMP_TAG_FILE}"
		for P in ${ALL_POSTS[@]}
		do
			if grep --quiet --line-regexp "${T}" "${P}"
			then
				ID="$(basename $(dirname "${P}"))"
				HEADERS="${METADATA_DIR}/${ID}/headers"
				DATE="$(get_date "${HEADERS}")"
				DATE_PRETTY="$(ts_to_date "${DATE_FRMT}" "$(get_date "${HEADERS}")")"
				if [[ "${TAG_INDEX_BY}" == "month" ]] && [[ "$(ts_to_date "${MONTHLY_INDEX_DATE_FRMT}" "${DATE}")" != "${CURRENT_EPOCH}" ]]
				then
					CURRENT_EPOCH="$(ts_to_date "${MONTHLY_INDEX_DATE_FRMT}" "${DATE}")"
					echo "</ul>" | tee -a "${TMP_TAG_FILE}"
					echo "<h2>${CURRENT_EPOCH}</h2>" | tee -a "${TMP_TAG_FILE}"
					echo "<ul>" | tee -a "${TMP_TAG_FILE}"
				elif [[ "${TAG_INDEX_BY}" == "year" ]] && [[ "$(ts_to_date "${YEARLY_INDEX_DATE_FRMT}" "${DATE}")" != "${CURRENT_EPOCH}" ]]
				then
					CURRENT_EPOCH="$(ts_to_date "${YEARLY_INDEX_DATE_FRMT}" "${DATE}")"
					echo "</ul>" | tee -a "${TMP_TAG_FILE}"
					echo "<h2>${CURRENT_EPOCH}</h2>" | tee -a "${TMP_TAG_FILE}"
					echo "<ul>" | tee -a "${TMP_TAG_FILE}"
				fi
				TITLE="$(get_title "${HEADERS}")"
				if [[ "${PREFER_SHORT_POSTS}" == "yes" ]]
				then
					LINK="/p/${ID}.html"
				else
					LINK="/posts/$(echo "${TITLE}" | title_to_post_url)${TITLE_SEPARATOR_CHAR}${ID}.html"
				fi
				AUTHOR="$(get_author "${HEADERS}")"
				echo "<li><a href='${LINK}'>${TITLE}</a> by ${AUTHOR} on ${DATE_PRETTY}</li>" | tee -a "${TMP_TAG_FILE}"
			fi
		done
		echo "</ul>" | tee -a "${TMP_TAG_FILE}"
		echo "CONTENT_PAGE_FOOTER_HTML([[${ROOT_URL}]], [[${VERSION}]])" >> "${TMP_TAG_FILE}"
		echo "END_HTML" >> "${TMP_TAG_FILE}"
		cat "${TMP_TAG_FILE}" | "${M4}" ${M4_FLAGS} > "${TAG_FILE}"
		rm "${TMP_TAG_FILE}"
	done
	echo "CONTENT_PAGE_FOOTER_HTML([[${ROOT_URL}]], [[${VERSION}]])"
	echo "END_HTML"
}

function build_postindex {
	ALL_POSTS=( $(find "${METADATA_DIR}/" -mindepth 2 -type f -name headers) )
	ALL_POSTS=( $(sort_by_date ${ALL_POSTS[@]} | tac) )
	CURRENT_EPOCH=
	echo "m4_include(include/html.m4)"
	echo "START_HTML([[${ROOT_URL}]], [[${BLOG_TITLE} - Home]])"
	echo "CONTENT_PAGE_HEADER_HTML([[${ROOT_URL}]], [[${BLOG_TITLE}]], [[${BLOG_SUBTITLE}]])"
	echo "<h1>Posts</h1>"
	echo "<ul>"
	for P in ${ALL_POSTS[@]}
	do
		ID="$(basename $(dirname "${P}"))"
		TITLE="$(get_title "${P}")"
		if [[ "${PREFER_SHORT_POSTS}" == "yes" ]]
		then
			LINK="/p/${ID}.html"
		else
			LINK="/posts/$(echo "${TITLE}" | title_to_post_url)${TITLE_SEPARATOR_CHAR}${ID}.html"
		fi
		AUTHOR="$(get_author "${P}")"
		DATE="$(get_date "${P}")"
		DATE_PRETTY="$(ts_to_date "${DATE_FRMT}" "${DATE}")"
		if [[ "${POST_INDEX_BY}" == "month" ]] && [[ "$(ts_to_date "${MONTHLY_INDEX_DATE_FRMT}" "${DATE}")" != "${CURRENT_EPOCH}" ]]
		then
			CURRENT_EPOCH="$(ts_to_date "${MONTHLY_INDEX_DATE_FRMT}" "${DATE}")"
			echo "</ul>"
			echo "<h2>${CURRENT_EPOCH}</h2>"
			echo "<ul>"
		elif [[ "${POST_INDEX_BY}" == "year" ]] && [[ "$(ts_to_date "${YEARLY_INDEX_DATE_FRMT}" "${DATE}")" != "${CURRENT_EPOCH}" ]]
		then
			CURRENT_EPOCH="$(ts_to_date "${YEARLY_INDEX_DATE_FRMT}" "${DATE}")"
			echo "</ul>"
			echo "<h2>${CURRENT_EPOCH}</h2>"
			echo "<ul>"
		fi
		echo "<li><a href='${LINK}'>${TITLE}</a> by ${AUTHOR} on ${DATE_PRETTY}</li>"
	done
	echo "</ul>"
	echo "CONTENT_PAGE_FOOTER_HTML([[${ROOT_URL}]], [[${VERSION}]])"
	echo "END_HTML"
}
set +a
