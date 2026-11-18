<?php
// SPDX-License-Identifier: GPL-3.0-or-later
namespace OPNsense\WhoisdsNrd\Api;

use OPNsense\Base\ApiMutableModelControllerBase;

class SettingsController extends ApiMutableModelControllerBase
{
    protected static $internalModelClass = 'OPNsense\\WhoisdsNrd\\WhoisdsNrd';
    protected static $internalModelName = 'whoisdsnrd';
}
