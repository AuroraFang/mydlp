set PYTHONPATH=%PYHONPATH%;C:\workspace\mydlp-endpoint-win\EndPoint\Engine\mydlp\src\thrift\gen-py
set path=%path%;C:\workspace\mydlp-deployment-env\Python26
echo start python
set
python MyDLPBackendServer.py mydlp-backend-py.pid
