$:.unshift "./lib"
require 's3'
require 'wikicloth'

# Initial setup
begin
  Bucket.find_root('wiki')
rescue S3::NoSuchBucket
  wiki_owner = User.find_by_login('wiki')
  if wiki_owner.nil?
     class S3KeyGen
       include S3::Helpers
       def secret() generate_secret(); end;
       def key() generate_key(); end;
      end
      puts "** No wiki user found, creating the `wiki' user."
      wiki_owner = User.create :login => "wiki", :password => DEFAULT_PASSWORD,
        :email => "wiki@parkplace.net", :key => S3KeyGen.new.key(), :secret => S3KeyGen.new.secret(),
        :activated_at => Time.now
  end
  wiki_bucket = Bucket.create(:name => 'wiki', :owner_id => wiki_owner.id, :access => 438)
  templates_bucket = Bucket.create(:name => 'templates', :owner_id => wiki_owner.id, :access => 438)
  if defined?(Git)
    wiki_bucket.git_init
    templates_bucket.git_init
  else
    puts "Git support not found therefore Wiki history is disabled."
  end
end

module S3
class Application < Sinatra::Base

  WIKI_NAME = 'Wiki on Sinatra-S3'

  def wiki_layout(title)
    html = Builder::XmlMarkup.new
    html.html do
      html.head do
        html.title title
        html.style "@import '/control/s/css/control.css';", :type => 'text/css'
        html.style "@import '/control/s/css/wiki.css';", :type => 'text/css'
        html.style ".editsection { display:none }", :type => "text/css"
      end
      html.body do
        html.div :style => "text-align:left;padding:10px 0;width:700px;margin:0 auto" do
          html.h1 { html.a WIKI_NAME, :href => "/", :id => "title" }
        end
        html.div :id => "page" do
          if status <= 300
            html.div :class => "menu" do
              html.ul do
                rp = params
                html.li { html.a "Content", :href => env['REQUEST_PATH'], :class => (!rp.has_key?('edit') && !rp.has_key?('history') ? "active" : "") }
                html.li { html.a "Edit", :href => "#{env['REQUEST_PATH']}?edit", :class => (rp.has_key?('edit') ? "active" : "") }
                html.li { html.a "History", :href => "#{env['REQUEST_PATH']}?history", :class => (rp.has_key?('history') ? "active" : "") } if defined?(Git)
              end
            end
          end
          html.h1 env['REQUEST_PATH'] =~ /\/([^\/]+)$/ ? "#{$1.gsub('_',' ')}" : "Sinatra-S3 Wiki"
          yield html
        end
      end
    end
    status = 200
    headers['Content-Type'] = 'text/html'
    headers['Content-Length'] = html.target!.length.to_s
    html.target!
  end

  def edit_page
    wiki_layout("Edit Page") do |html|
      html.h2 "Edit Page"
      html.form :class => "create", :action => env['REQUEST_PATH'], :method => "POST" do
        html.input :type => "hidden", :name => "redirect", :value => env['REQUEST_PATH']
        html.input :type => "hidden", :name => "Content-Type", :value => "text/wiki"
        html.div :class => "required" do
           page_contents = status >= 300 ? "" : (response.body.respond_to?(:read) ? response.body.read : response.body.to_s)
           html.label "Contents", :for => "page_contents"
           html.textarea page_contents, :name => "file", :id => "page_contents", :style => "width:100%;height:20em"
        end
        html.div :class => "required" do
           html.label "Comment:", :for => "page_comment"
           html.input :type => "text", :name => "x-amz-meta-comment", :id => "page_comment"
        end
        html.input :type => "submit", :value => "Update"
      end
    end
  end

end
end

class CustomLinkHandler < WikiCloth::WikiLinkHandler

  def url_for(page)
    page = page.strip.gsub(/\s+/,'_')
    page = "/#{$1.downcase}/#{$2}" if page =~ /^([A-Za-z]+):(.*)$/
    page
  end

  def link_attributes_for(page)
     { :href => url_for(page) }
  end

  def external_link(url,text)
    self.external_links << url
    elem.a({ :href => url, :target => "_blank", :class => "exlink" }) { |x| x << (text.blank? ? url : text) }
  end

  def include_resource(resource,options=[])
    if params[resource].nil?
      begin
        bucket = Bucket.find_root('templates')
        slot = bucket.find_slot(resource)
        unless slot.nil?
          file = open(File.join(STORAGE_PATH, slot.obj.path))
          wiki_page = WikiCloth::WikiCloth.new({
            :data => file.instance_of?(File) ? file.read : file.to_s,
            :link_handler => self,
            :params => params
          })
          return wiki_page.to_html
        end
      rescue S3::NoSuchKey
        puts "Unknown resource #{resource}"
      end
    else
      return params[resource]
    end
  end

end

S3::Application.callback :mime_type => 'text/wiki' do
  if params.has_key?('edit')
    edit_page
  elsif params.has_key?('history')
    wiki_layout("Page History") do |html|
      html.h2 "Edit History"
      if env['REQUEST_PATH'] =~ /^\/(.+?)\/(.+)$/
        bucket = Bucket.find_root($1)
        revisions = Slot.find(:all, :conditions => [ 'name = ?', $2 ], :order => "id DESC")
        html.ul do
          revisions.each do |rev|
            html.li do
              html.p do
                html.a rev.meta['comment'], :href => "#{env['REQUEST_PATH']}?version-id=#{rev.version}"
                html << " on #{rev.updated_at}"
              end
            end
          end
        end
      end
    end
  else
    wiki_layout(" ") do |html|
      p = {}
      headers.each { |k,v| p[$1.upcase.gsub(/\-/,'_')] = v if k =~ /x-amz-(.*)/ }

      wiki_page = WikiCloth::WikiCloth.new({
        :data => response.body.respond_to?(:read) ? response.body.read : response.body.to_s,
        :link_handler => CustomLinkHandler.new,
        :params => p
      })

      html << wiki_page.to_html
    end
  end
end

S3::Application.callback :error => 'NoSuchKey' do
  if params.has_key?('edit')
    edit_page
  else
    wiki_layout("Page Does Not Exist") do |html|
      html.h2 "Page Does Not Exist"
      html.p { html << "The page you were trying to access does not exist.  Perhaps you would like to <a href=\"#{env['REQUEST_PATH']}?edit\">create it</a>?" }
    end
  end
end

S3::Application.callback :error => 'AccessDenied' do
  redirect '/wiki/Main_Page' if env['REQUEST_PATH'].nil? || env['REQUEST_PATH'] == '/'
end

use S3::Tracker if defined?(RubyTorrent)
use S3::Admin
run S3::Application