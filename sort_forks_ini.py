#!/usr/bin/env python

import configparser


def sort_forks_ini_file(file_path):
    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(file_path)

    # 1. Sort the internal list inside [Forks] -> SYNCING_FORKS
    if config.has_option("Forks", "SYNCING_FORKS"):
        raw_value = config.get("Forks", "SYNCING_FORKS")
        # Split by whitespace, sort, and join back with a single space
        forks_list = sorted(raw_value.split())
        sorted_forks_string = " ".join(forks_list)
        config.set("Forks", "SYNCING_FORKS", sorted_forks_string)

    # 2. Organize Section Order
    other_sections = [s for s in config.sections() if s != "Forks"]
    other_sections.sort()
    new_order = ["Forks"] + other_sections

    # 3. Rebuild the config to apply orders
    sorted_config = configparser.ConfigParser()
    sorted_config.optionxform = str

    for section in new_order:
        sorted_config.add_section(section)
        # Preserve original key order within sections
        for key, value in config.items(section):
            sorted_config.set(section, key, value)

    # 4. Save (Comments will be removed)
    with open(file_path, "w") as configfile:
        sorted_config.write(configfile)


sort_forks_ini_file("Forks.ini")
