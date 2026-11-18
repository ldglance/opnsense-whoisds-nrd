# SPDX-License-Identifier: GPL-3.0-or-later
PLUGIN_NAME=        whoisds-nrd
PLUGIN_PYTHON?=     313
PLUGIN_VERSION=     1.0
PLUGIN_REVISION=    1
PLUGIN_COMMENT=     WhoisDS Newly Registered Domains feed manager for Unbound
PLUGIN_MAINTAINER=  maintainers@example.invalid
PLUGIN_DEPENDS=     python${PLUGIN_PYTHON}

.include "../../Mk/plugins.mk"
