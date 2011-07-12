## @author    Pete Birkinshaw (<pete@digitalidentitylabs.com>)
## Copyright: Copyright (c) 2011 Digital Identity Ltd.
## License:   Apache License, Version 2.0

## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
## 
##     http://www.apache.org/licenses/LICENSE-2.0
## 
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##

module Shibkit
  class MetaMeta

    ## Class to represent the metadata of the organisation owning a Shibboleth entity
    class Attribute < MetadataItem
      
      require 'shibkit/meta_meta/metadata_item'
      
      ## Element and attribute used to select XML for new objects
      ROOT_ELEMENT = 'Attribute'
      TARGET_ATTR  = nil
      REQUIRED_QUACKS = [:name, :url]
      
      ## The name identifier for the organisation
      attr_accessor :name
      
      ## The human-readable display name for the organisation
      attr_accessor :display_name
      
      ## The homepage URL for the organisation
      attr_accessor :url
    
    
     private
     
     def parse_xml
    
      name         = @xml.xpath('xmlns:OrganizationName[1]')[0].content
      display_name = @xml.xpath('xmlns:OrganizationDisplayName[1]')[0].content
      url          = @xml.xpath('xmlns:OrganizationURL[1]')[0].content
      
    end
        
    end
  end
end