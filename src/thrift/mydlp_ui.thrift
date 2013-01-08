/**
 *     Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@medra.com.tr>
 * 
 ***************************************************************************
 *     This file is part of MyDLP.
 * 
 *     MyDLP is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 * 
 *     MyDLP is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 * 
 *     You should have received a copy of the GNU General Public License
 *     along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
 ***************************************************************************/

namespace java com.mydlp.ui.thrift

struct LicenseObject {
  1: string license_type,
  2: i64 number_of_users,
  3: i64 administrative_users,
  4: i64 expiration_date,
  5: bool is_trial,
  6: bool is_valid
}


service Mydlp_ui {

	void compileCustomer(1: i32 Customerid)
	string getCompileStatus()

	binary getRuletable(1: string endpointId, 2: string Ipaddress, 3: string Userh, 4: string Revisionid)

	string receiveBegin(1: string Ipaddress)
	string receiveChunk(1: string Ipaddress, 2: i64 Itemid, 3: binary Chunkdata, 4: i32 Chunknum, 5: i32 Chunknumtotal)

	void generateFingerprints(1: i64 DocumentId, 2: string Filename, 3: binary Data)

	void generateFingerprintsWithFile(1: i64 DocumentId, 2: string Filename, 3: string Filepath)

	oneway void requeueIncident(1: i64 Incidentid)

	map<string,string> registerUserAddress(1: string Ipaddress, 2: string Userh, 3: binary Payload)

	string saveLicenseKey(1: string licenseKey)

	LicenseObject getLicense()

	string apiQuery(1: string Ipaddress, 2: string Filename, 3: binary Data)

	oneway void registerCommand(1: string EndpointId, 2: string Command)
}
