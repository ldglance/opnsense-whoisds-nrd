<?php
// SPDX-License-Identifier: GPL-3.0-or-later
namespace OPNsense\WhoisdsNrd;

class IndexController extends \OPNsense\Base\IndexController
{
    public function indexAction()
    {
        $this->view->generalForm = $this->getForm('general');
        $this->view->pick('OPNsense/WhoisdsNrd/index');
    }
}
