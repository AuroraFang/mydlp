#!/usr/bin/env python

###--------------------------------------------------------------------------
###
###    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@medra.com.tr>
###
###--------------------------------------------------------------------------
###    This file is part of MyDLP.
###
###    MyDLP is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    MyDLP is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###    GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
###--------------------------------------------------------------------------


from mydlp import Mydlp
from mydlp.ttypes import *

from thrift.transport import TSocket
from thrift.transport import TTransport
from thrift.protocol import TBinaryProtocol
from thrift.server import TServer

import magic

from pdfminer.pdfinterp import PDFResourceManager, process_pdf 
from pdfminer.pdfdevice import PDFDevice 
from pdfminer.converter import TextConverter 
from pdfminer.layout import LAParams 

import StringIO 

class MydlpHandler:
	def __init__(self):
		self.mime = magic.open(magic.MAGIC_MIME)
		self.mime.load()

		self.rsrcmgr = PDFResourceManager()

	def getMagicMime(self, data):
		mtype = self.mime.buffer(data)
		sc = mtype.find(';')
		if sc == -1:
			return mtype
		else:
			return mtype[0:sc]

	def getPdfText(self, data):
		fp = StringIO.StringIO() 
		fp.write(data) 
		fp.seek(0) 
		outfp = StringIO.StringIO() 

		rsrcmgr = PDFResourceManager() 
		device = TextConverter(rsrcmgr, outfp, laparams=LAParams()) 
		process_pdf(rsrcmgr, device, fp) 
		device.close() 

		t = outfp.getvalue() 
		outfp.close() 
		fp.close() 
		return t

handler = MydlpHandler()

processor = Mydlp.Processor(handler)
transport = TSocket.TServerSocket(9090)
tfactory = TTransport.TBufferedTransportFactory()
pfactory = TBinaryProtocol.TBinaryProtocolFactory()


#server = TServer.TSimpleServer(processor, transport, tfactory, pfactory)
#server = TServer.TThreadedServer(processor, transport, tfactory, pfactory)
server = TServer.TThreadPoolServer(processor, transport, tfactory, pfactory)

print 'Starting MyDLP Backend server...'
server.serve()
print 'done.'
