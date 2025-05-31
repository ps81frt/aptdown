#!/bin/bash
deps() {
	echo "Missing dependencies, run:\n  sudo apt-get install aptitude grep"
	exit 1
}

if ! command -v aptitude &>/dev/null; then
	deps
fi
if ! command -v grep &>/dev/null; then
	deps
fi
if [ "$EUID" -ne 0 ]; then
	echo "Please run as root"
	exit 1
fi

# Update package information and downgrade dash first
sudo apt-get update
apt-get download dash
sudo dpkg -i /tmp/dash_*.deb
rm dash_*.deb

aptitude keep-all # delete all previously scheduled actions

manual_packages="$(apt-mark showmanual)"
get_package_state() {
	# if the package is manually installed, return "&m", which is the aptitude syntax for manual
	# else return "&M", which is the aptitude syntax for automatic
	match=$(grep -q "^$1$" <<<"$manual_packages")
	if [[ $? -eq 0 ]]; then
		echo ""
	else
		echo "+M"
	fi
}

get_package_policy() {
	local package=$1
	# Get the version table for the package
	version_table=$(apt-cache policy $package)
	# Get the candidate version for the package
	candidate_version=$(echo "$version_table" | grep 'Candidate:' | cut -d ' ' -f 4)
	if ! apt-cache madison "$package" | grep -q "$candidate_version"; then
		candidate_version="(none)"
	fi
	# Extract the priority of the candidate version
	candidate_priority=$(echo "$version_table" | grep "$candidate_version" | tr ' ' '\n' | tail -n 1)
	# Return the array
	echo $candidate_priority $candidate_version
}

# Get the list of installed packages using the current status
installed_packages=$(dpkg -l | grep '^.i' | cut -d ' ' -f 3)

scheduled_actions=""
# Loop through each installed package
for package in $installed_packages; do

	# Get the version of the package provided by the release with the highest priority
	policy=($(get_package_policy $package))
	package_priority=${policy[0]}
	package_version=${policy[1]}

	# Check if the package is not provided by any release
	if [[ "$package_version" == "(none)" ]]; then
		# If not, set it as deinstall
		echo " - Keeping package $package as it is not provided by any release"
		continue
	fi
	# Check if the package replaces other packages
	# -f 2- means that we are cutting the first field and keeping the rest
	# -f 2 is used because after a ',' there is a space, which will be the first field
	replaced_packages=$(apt-cache show $package | grep "Replaces:" | cut -d ':' -f 2- | tr ',' '\n' | cut -d ' ' -f 2)

	# take the package with the highest priority
	largest_priority="$package_priority"
	version_to_install="$package_version"
	package_to_install=$package
	for replaced_package in $replaced_packages; do
		replaced_policy=($(get_package_policy $replaced_package))
		replaced_priority=${replaced_policy[0]}
		replaced_version=${replaced_policy[1]}
		# If yes, compare the priorities of the replacing package and the replaced package
		if [[ "$largest_priority" -lt "$replaced_priority" ]]; then
			# If the replacing package has a larger priority than the current largest
			# priority
			largest_priority=$replaced_priority
			version_to_install=$replaced_version
			package_to_install=$replaced_package
		fi
	done
	if [[ $package_to_install != $package ]]; then
		echo " - >> Found name mismatching: $package <-> $package_to_install! deinstalling $package (priority $package_priority) and installing $package_to_install (priority $largest_priority)"
		scheduled_actions="$scheduled_actions $package-"
		echo " - Package $package is replaced by $package_to_install"
		package=$package_to_install
		package_version=$version_to_install
	fi
	package_state=$(get_package_state $package)
	if [[ $package_state == "+M" ]]; then
		echo " - AUTOMATICALLY installing $package=$package_version"
	else
		echo " - MANUALLY installing $package=$package_version"
	fi
	scheduled_actions="$scheduled_actions $package=$package_version$package_state"
done

echo "$scheduled_actions" >aptitude_command.sh # debugging

aptitude install $scheduled_actions

# Apply the selections
echo "Applied package selections"

if [[ $? -ne 0 ]]; then
	echo "An error occurred while resolving dependencies"
	exit 1
else
	echo "Resolved dependencies"
fi