<?php
// SPDX-License-Identifier: GPL-3.0-or-later
namespace OPNsense\WhoisdsNrd\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Core\Backend;

class ServiceController extends ApiControllerBase
{
    private function runActionCommand(string $command): array
    {
        $result = trim((new Backend())->configdRun($command));
        $decoded = json_decode($result, true);
        return $decoded !== null ? $decoded : ['output' => $result];
    }

    public function statusAction()
    {
        if (!$this->request->isGet()) return ['error' => 'GET required'];
        return $this->runActionCommand('whoisds_nrd status');
    }

    public function updateAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd update');
    }

    public function clearAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd clear');
    }

    public function refreshAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd refresh');
    }


    public function reloadAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        $result = trim((new Backend())->configdRun('template reload OPNsense/WhoisdsNrd'));
        return ['status' => strtolower($result) === 'ok' ? 'ok' : 'failed', 'output' => $result];
    }

    public function rebuildAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd rebuild');
    }

    public function startAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd service.start');
    }

    public function stopAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd service.stop');
    }

    public function restartAction()
    {
        if (!$this->request->isPost()) return ['error' => 'POST required'];
        return $this->runActionCommand('whoisds_nrd service.restart');
    }
}
