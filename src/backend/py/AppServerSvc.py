import pythoncom
import win32serviceutil
import win32service
import win32event
import servicemanager
import socket

import MyDLPBackendServer

class AppServerSvc (win32serviceutil.ServiceFramework):
    _svc_name_ = "MyDLP Backend"
    _svc_display_name_ = "MyDLP Backend"

    def __init__(self,args):
        win32serviceutil.ServiceFramework.__init__(self,args)
        self.hWaitStop = win32event.CreateEvent(None,0,0,None)
        socket.setdefaulttimeout(60)
        self.mydlpbackend = MyDLPBackendServer.MyDLPBackendServer("")

    def SvcStop(self):
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        win32event.SetEvent(self.hWaitStop)
	self.mydlpbackend.stop()

    def SvcDoRun(self):
        servicemanager.LogMsg(servicemanager.EVENTLOG_INFORMATION_TYPE,
                              servicemanager.PYS_SERVICE_STARTED,
                              (self._svc_name_,''))
        self.mydlpbackend.run()

if __name__ == '__main__':
    win32serviceutil.HandleCommandLine(AppServerSvc)

