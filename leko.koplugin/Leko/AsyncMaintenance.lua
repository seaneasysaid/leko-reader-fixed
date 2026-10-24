local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")

local AsyncMaintenance = {
    worker = nil,
    budget_ticket = nil,
    poll_interval = 0.5,
    reap_interval = 0.25,
    run_interval = 30 * 60,
    scheduled = nil,
}

function AsyncMaintenance:_release(worker)
    if worker and worker.budget_ticket then
        ProcessBudget:release(worker.budget_ticket)
        worker.budget_ticket = nil
    end
    self.budget_ticket = nil
end

-- Each pass only deletes a bounded number of files, so the series has to keep
-- running. Every terminal path (finished, preempted, failed to spawn) arms the
-- next pass; otherwise one interrupted pass disables maintenance for the rest
-- of the session.
function AsyncMaintenance:schedule(delay)
    if self.worker or self.budget_ticket then return end
    if self.scheduled then
        local pending = self.scheduled
        self.scheduled = nil
        pcall(function() UIManager:unschedule(pending) end)
    end
    self.scheduled = UIManager:scheduleIn(delay or self.run_interval, function()
        self.scheduled = nil
        self:start()
    end)
end

function AsyncMaintenance:_poll(worker)
    if self.worker ~= worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then
        worker.finished = true
        self.worker = nil
        self:_release(worker)
        self:schedule()
    else
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end
end

function AsyncMaintenance:_preempt()
    local worker = self.worker
    if not worker or worker.finished then return end
    worker.finished = true
    self.worker = nil
    ffiutil.terminateSubProcess(worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            self:_release(worker)
            self:schedule()
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncMaintenance:start()
    if self.worker or self.budget_ticket then return end
    local ticket
    ticket = ProcessBudget:request{
        owner = self,
        label = "cache-maintenance",
        priority = 1,
        on_start = function(granted)
            self.budget_ticket = granted
            local pid = ffiutil.runInSubProcess(function()
                -- Storage:pruneCaches bounds how many entries one pass removes.
                pcall(Storage.pruneCaches, Storage)
            end, false)
            if not pid then
                ProcessBudget:release(granted)
                self.budget_ticket = nil
                self:schedule()
                return
            end
            local worker = { pid = pid, finished = false, budget_ticket = granted }
            self.worker = worker
            granted.on_preempt = function() self:_preempt() end
            UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
        end,
        on_preempt = function() self:_preempt() end,
        on_error = function()
            self.budget_ticket = nil
            self:schedule()
        end,
    }
    if ticket.state == "queued" then self.budget_ticket = ticket end
end

function AsyncMaintenance:cancel()
    if self.scheduled then
        local pending = self.scheduled
        self.scheduled = nil
        pcall(function() UIManager:unschedule(pending) end)
    end
    if self.budget_ticket and not self.worker then
        ProcessBudget:cancel(self.budget_ticket)
        self.budget_ticket = nil
    elseif self.worker then
        self:_preempt()
    end
end

return AsyncMaintenance
