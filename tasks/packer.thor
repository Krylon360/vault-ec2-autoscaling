require 'aws-sdk'
require 'csv'
require 'faraday'
require 'fileutils'
require 'json'
require 'pty'
require 'time'
require 'thor/actions'

class Packer < Thor
  include Thor::Actions

  ROOT_DIR = File.expand_path('../..', __FILE__)
  PACKER_DIR = File.join(ROOT_DIR, 'packer')
  TMP_DIR = File.join(ROOT_DIR, 'tmp')

  source_root(ROOT_DIR)

  class_option :region, type: :string, desc: 'The AWS region', default: ENV['AWS_REGION']

  desc 'build IMAGE', 'Build the specified image'
  method_option :providers, type: :array, desc: 'Build only the specified providers', default: %w(amazon-ebs)
  method_option :stack, type: :string, desc: 'The CloudFormation stack to use', default: ENV['IMAGE_BUILD_STACK']
  method_option :verbose, type: :boolean, desc: 'Print verbose output', default: false
  method_option :base_image, type: :string, desc: 'The base image to use'
  method_option :base_version, type: :numeric, desc: 'Version of the base image to use'
  def build(image)
    version = Time.now.utc.strftime('%Y%m%d%H%M%S')
    template = "#{image}.json"
    template_path = File.join(PACKER_DIR, template)

    variables = JSON.parse(IO.read(template_path))['variables']
    root_storage = variables['root_storage']
    virtualization = variables['virtualization']

    base_image = options['base_image'] || variables['base_image']
    base_version = options['base_version'] || variables['base_version']
    if base_image
      source_ami = base_image_ami(base_image, base_version)

      unless source_ami
        say 'Unable to find that base image'
        return
      end
    else
      source_ami = latest_ami(image, virtualization, root_storage)
    end

    source_ami_metadata = ec2.image(source_ami)
    source_ami_tags = parse_tags(source_ami_metadata.tags)

    (say "No image found for #{image}" && return) unless File.exist?(template_path)

    packer_cmd = 'packer build'
    packer_cmd << " -only=#{options[:providers].join(',')}"
    packer_cmd << " -var 'region=#{region}'"
    packer_cmd << " -var 'source_ami=#{source_ami}'"
    packer_cmd << " -var 'version=#{version}'"
    packer_cmd << " -var 'aws_access_key_id=#{build_stack_output('BuildAccessKeyId')}'"
    packer_cmd << " -var 'aws_secret_access_key=#{build_stack_output('BuildSecretAccessKey')}'"
    packer_cmd << " -var 'build_security_group=#{build_stack_output('BuildSecurityGroupId')}'"
    packer_cmd << " -var 'build_vpc=#{build_stack_output('VpcId')}'"
    packer_cmd << " -var 'build_subnet=#{build_stack_output('BuildSubnetId')}'"
    packer_cmd << " -var 'build_instance_profile=#{build_stack_output('BuildInstanceProfileName')}'"

    if base_image
      packer_cmd << " -var 'base_image=#{base_image}'"
      packer_cmd << " -var 'base_version=#{source_ami_tags['Version']}'"
    end

    packer_cmd << " #{template}"
    output_ami = nil

    begin
      Dir.chdir(PACKER_DIR) do
        PTY.spawn(packer_cmd) do |stdout, stdin, pid|
          begin
            stdout.each do |line|
              match = line.match(/#{region}: (ami-[a-z0-9]{8})/)
              output_ami = match[1] if match
              print line
            end
          rescue Errno::EIO
          end
        end
      end

      if $!.nil? || $!.is_a?(SystemExit) && $!.success?
        say "Created the image successfully: #{output_ami}"
      else
        say 'Something went wrong. Check Packer output above for details'
        exit($!.is_a?(SystemExit) ? $!.status.exitstatus : 1)
      end
    rescue PTY::ChildExited => e
      status = e.status.exitstatus
      say "The Packer process exited: #{status}"
      exit(status) unless status == 0
    end

    unless output_ami
      say 'Something went wrong. Check Packer output above for details'
      exit(1)
    end

    output_ami_metadata = ec2.image(output_ami)
    output_ami_tags = parse_tags(output_ami_metadata.tags)

    item = {
      'AMI'            => output_ami,
      'AMIName'        => output_ami_metadata.name,
      'CreatedAt'      => output_ami_metadata.creation_date,
      'Name'           => image,
      'Region'         => region,
      'RootDeviceName' => output_ami_metadata.root_device_name,
      'RootDeviceType' => output_ami_metadata.root_device_type,
      'SourceAMI'      => source_ami,
      'SourceAMIName'  => source_ami_metadata.name,
      'Tags'           => output_ami_tags.to_json,
      'Version'        => output_ami_tags['Version'].to_i,
      'Virtualization' => output_ami_metadata.virtualization_type
    }

    item.merge!(
      'BaseImage' => base_image,
      'BaseVersion' => source_ami_tags['Version'].to_i
    ) if base_image

    say "Indexing image in #{repository.table_name}"

    repository.put_item(item: item)

    say "Successfully indexed image in #{repository.table_name}"
  end

  desc 'latest_image IMAGE', 'Fetch information about the latest image'
  def latest_image(image)
    results = repository.query(
      consistent_read: true,
      scan_index_forward: false,
      limit: 1,
      key_condition_expression: %{#n = :n},
      expression_attribute_names: { '#n' => 'Name' },
      expression_attribute_values: { ':n' => image }
    ).items

    if results.empty?
      say 'No results for that base image'
    else
      image_result = results.first

      require 'terminal-table'
      table = Terminal::Table.new do |t|
        image_result.each { |(k, v)| t << [k, (v.is_a?(BigDecimal) ? v.to_i : v)] }
      end
      say table
    end
  end

  desc 'latest_source', 'Fetch the ID of the latest source AMI'
  method_option :root_storage, type: :string, desc: 'Root storage type (ebs ebs-ssd instance-store)', default: 'ebs-ssd'
  method_option :virtualization, type: :string, desc: 'Virtualization type (hvm or pv)', default: 'hvm'
  def latest_source
    say latest_ami('14.04', parse_virtualization(options[:virtualization]), options[:root_storage])
  end

  desc 'stack', 'Fetch information about the specified build stack'
  method_option :stack, type: :string, desc: 'The CloudFormation stack to use', default: ENV['IMAGE_BUILD_STACK']
  def stack
    require 'terminal-table'
    table = Terminal::Table.new do |t|
      build_stack.outputs.each do |output|
        t << [output.output_key, output.output_value]
      end
    end
    say table
  end

  private

  def region
    options[:region]
  end

  def parse_tags(ec2_tags)
    ec2_tags.each_with_object({}) { |tag, tags| tags[tag.key] = tag.value }
  end

  def parse_virtualization(image)
    match = image.match('(hvm|pv)')
    if match
      return 'paravirtual' if match[1] == 'pv'
      match[1]
    else
      'hvm'
    end
  end

  def build_stack
    @build_stack ||=
      begin
        cloudformation.stack(options[:stack])
      end
  end

  def build_stack_output(key)
    output = build_stack.outputs.find { |o| o.output_key == key }
    return unless output

    output.output_value
  end

  def cloudformation
    @cloudformation ||= Aws::CloudFormation::Resource.new
  end

  def dynamodb
    @dynamodb ||= Aws::DynamoDB::Resource.new
  end

  def ec2
    @ec2 ||= Aws::EC2::Resource.new
  end

  def repository
    @repository ||=
      begin
        table = build_stack_output('BuildImagesTable')
        dynamodb.table(table)
      end
  end

  def base_image_ami(name, version = 'latest')
    query_options = {
      consistent_read: true,
      scan_index_forward: false,
      limit: 1,
      expression_attribute_names: { '#n' => 'Name' }
    }

    if version.nil? || version == 'latest'
      query_options.merge!(
        key_condition_expression: %{#n = :n},
        expression_attribute_values: { ':n' => name }
      )
    else
      query_options.merge!(
        key_condition_expression: %{#n = :n and Version = :v},
        expression_attribute_values: { ':n' => name, ':v' => version }
      )
    end

    results = repository.query(query_options).items
    return if results.empty?

    results.first['AMI']
  end

  def latest_ami(image, virtualization, root_storage)
    distribution = distribution_from_image(image)
    connection = Faraday::Connection.new('https://cloud-images.ubuntu.com')
    response = connection.get("/query/#{distribution}/server/released.current.txt")
    parsed = CSV.parse(response.body, col_sep: "\t")
    row = parsed.find do |r|
      r[4] == root_storage &&
      r[5] == 'amd64' &&
      r[6] == region &&
      r[10] == virtualization
    end
    row[7]
  end

  def distribution_from_image(name)
    case name
    when /12\.04/
      'precise'
    when /14\.04/
      'trusty'
    end
  end
end
